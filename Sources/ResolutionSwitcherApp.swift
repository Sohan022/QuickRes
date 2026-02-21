import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ServiceManagement

private struct ModeDescriptor: Hashable {
    let width: Int
    let height: Int
    let refreshMilliHz: Int
    let isHiDPI: Bool

    init(mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        refreshMilliHz = Int((mode.refreshRate * 1000.0).rounded())
        isHiDPI = mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
    }
}

private struct StoredMode: Codable, Hashable {
    let width: Int
    let height: Int
    let refreshMilliHz: Int
    let isHiDPI: Bool

    init(mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        refreshMilliHz = Int((mode.refreshRate * 1000.0).rounded())
        isHiDPI = mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
    }

    func matches(_ mode: CGDisplayMode) -> Bool {
        width == mode.width &&
            height == mode.height &&
            refreshMilliHz == Int((mode.refreshRate * 1000.0).rounded()) &&
            isHiDPI == (mode.pixelWidth > mode.width || mode.pixelHeight > mode.height)
    }
}

private struct CuratedModeKey: Hashable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
}

private final class ModeSelection: NSObject {
    let displayID: CGDirectDisplayID
    let mode: CGDisplayMode

    init(displayID: CGDirectDisplayID, mode: CGDisplayMode) {
        self.displayID = displayID
        self.mode = mode
        super.init()
    }
}

private final class DisplaySelection: NSObject {
    let displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()
    }
}

private struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let currentMode: CGDisplayMode
    let modes: [CGDisplayMode]
}

private enum DisplayManagerError: Error, LocalizedError {
    case noConfig
    case beginFailed(CGError)
    case configureFailed(CGError)
    case completeFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .noConfig:
            return "Could not create display configuration."
        case .beginFailed(let error):
            return "Failed to begin display configuration (\(error.rawValue))."
        case .configureFailed(let error):
            return "Failed to configure display mode (\(error.rawValue))."
        case .completeFailed(let error):
            return "Failed to apply display mode (\(error.rawValue))."
        }
    }
}

private final class DisplayManager {
    func allDisplays() -> [DisplayInfo] {
        var displayCount: UInt32 = 0
        var activeDisplayIDs = Array<CGDirectDisplayID>(repeating: 0, count: 32)
        let result = CGGetActiveDisplayList(UInt32(activeDisplayIDs.count), &activeDisplayIDs, &displayCount)
        guard result == .success else {
            return []
        }

        let screenNames = screenNameMap()
        let displayIDs = activeDisplayIDs.prefix(Int(displayCount))

        return displayIDs.compactMap { displayID in
            guard let currentMode = CGDisplayCopyDisplayMode(displayID) else {
                return nil
            }
            let modes = filteredModes(for: displayID)
            let title = screenNames[displayID] ?? defaultName(for: displayID)
            return DisplayInfo(id: displayID, name: title, currentMode: currentMode, modes: modes)
        }
        .sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    func setDisplayMode(displayID: CGDirectDisplayID, mode: CGDisplayMode) throws {
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success else {
            throw DisplayManagerError.beginFailed(beginResult)
        }
        guard let config else {
            throw DisplayManagerError.noConfig
        }

        let configureResult = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayManagerError.configureFailed(configureResult)
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeResult == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayManagerError.completeFailed(completeResult)
        }
    }

    private func filteredModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let allModes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []

        var seen = Set<ModeDescriptor>()
        var modes = [CGDisplayMode]()
        for mode in allModes where mode.isUsableForDesktopGUI() {
            let key = ModeDescriptor(mode: mode)
            if seen.insert(key).inserted {
                modes.append(mode)
            }
        }

        return modes.sorted { lhs, rhs in
            let leftPixels = lhs.width * lhs.height
            let rightPixels = rhs.width * rhs.height
            if leftPixels != rightPixels {
                return leftPixels > rightPixels
            }
            if lhs.refreshRate != rhs.refreshRate {
                return lhs.refreshRate > rhs.refreshRate
            }
            return lhs.ioDisplayModeID > rhs.ioDisplayModeID
        }
    }

    private func screenNameMap() -> [CGDirectDisplayID: String] {
        var names = [CGDirectDisplayID: String]()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            names[number.uint32Value] = screen.localizedName
        }
        return names
    }

    private func defaultName(for id: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hotKeySignature: OSType = 0x51525253 // "QRRS"
    private static let hotKeyHandler: EventHandlerUPP = { _, event, _ in
        guard let event else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == hotKeySignature else {
            return noErr
        }

        sharedForHotKeys?.handlePreviousModeHotKey(slot: Int(hotKeyID.id))
        return noErr
    }
    private static weak var sharedForHotKeys: AppDelegate?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let displayManager = DisplayManager()
    private let defaults = UserDefaults.standard
    private let showAllModesKey = "showAllModesAdvanced"
    private let riskAckPrefix = "riskAcknowledged"
    private let favoritesKey = "favoriteModesByDisplay"
    private let previousModeKey = "previousModesByDisplay"
    private let maxFavoritesPerDisplay = 4
    private let hotKeyHint = "Hotkey: Ctrl+Option+Cmd+[1-9] toggles Previous Mode"
    private let hotKeyKeyCodes: [Int: UInt32] = [
        1: UInt32(kVK_ANSI_1),
        2: UInt32(kVK_ANSI_2),
        3: UInt32(kVK_ANSI_3),
        4: UInt32(kVK_ANSI_4),
        5: UInt32(kVK_ANSI_5),
        6: UInt32(kVK_ANSI_6),
        7: UInt32(kVK_ANSI_7),
        8: UInt32(kVK_ANSI_8),
        9: UInt32(kVK_ANSI_9),
    ]
    private var lastErrorMessage: String?
    private var displaysByID = [CGDirectDisplayID: DisplayInfo]()
    private var displaySlotsByNumber = [Int: CGDirectDisplayID]()
    private var displaySlotsByDisplayID = [CGDirectDisplayID: Int]()
    private var favoritesByDisplay = [String: [StoredMode]]()
    private var previousModeByDisplay = [String: StoredMode]()
    private var hotKeyRefs = [Int: EventHotKeyRef]()
    private var hotKeyHandlerRef: EventHandlerRef?

    private var showAllModes: Bool {
        get { defaults.bool(forKey: showAllModesKey) }
        set { defaults.set(newValue, forKey: showAllModesKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadPersistedSettings()
        try? refreshLaunchAgentIfEnabled()
        Self.sharedForHotKeys = self
        registerHotKeys()
        configureStatusItem()
        installObservers()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKeys()
        Self.sharedForHotKeys = nil
        removeObservers()
    }

    @objc func rebuildMenu() {
        let menu = NSMenu()

        if let lastErrorMessage {
            let errorItem = NSMenuItem(title: "Last error: \(lastErrorMessage)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        let displays = displayManager.allDisplays()
        displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        displaySlotsByNumber = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.offset + 1, $0.element.id) })
        displaySlotsByDisplayID = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.element.id, $0.offset + 1) })
        if displays.isEmpty {
            let empty = NSMenuItem(title: "No displays found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in displays {
                menu.addItem(makeDisplayItem(display))
            }
        }

        menu.addItem(.separator())
        let hotKeyItem = NSMenuItem(title: hotKeyHint, action: nil, keyEquivalent: "")
        hotKeyItem.isEnabled = false
        menu.addItem(hotKeyItem)

        let launchAtLogin = makeLaunchAtLoginMenuItem()
        menu.addItem(launchAtLogin)
        if shouldShowLaunchAtLoginHelpText {
            let help = NSMenuItem(title: launchAtLoginHelpText, action: nil, keyEquivalent: "")
            help.isEnabled = false
            menu.addItem(help)
        }

        let advanced = NSMenuItem(
            title: "Show All Modes (Advanced)",
            action: #selector(toggleShowAllModes(_:)),
            keyEquivalent: ""
        )
        advanced.target = self
        advanced.state = showAllModes ? .on : .off
        menu.addItem(advanced)
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(rebuildMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func changeMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModeSelection else {
            return
        }
        guard let display = displaysByID[selection.displayID] else {
            return
        }

        if shouldConfirmRiskyMode(selection.mode, on: display),
           !riskWasAcknowledged(displayID: selection.displayID, mode: selection.mode) {
            let confirmed = confirmRiskySwitch(mode: selection.mode, display: display)
            guard confirmed else {
                return
            }
            acknowledgeRisk(displayID: selection.displayID, mode: selection.mode)
        }

        applyModeChange(on: display, to: selection.mode)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleShowAllModes(_ sender: NSMenuItem) {
        showAllModes.toggle()
        rebuildMenu()
    }

    @objc private func togglePreviousModeFromMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? DisplaySelection,
              let display = displaysByID[selection.displayID] else {
            return
        }
        togglePreviousMode(on: display)
    }

    @objc private func toggleCurrentModeFavorite(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? DisplaySelection,
              let display = displaysByID[selection.displayID] else {
            return
        }

        var favorites = storedFavorites(for: display.id)
        let current = StoredMode(mode: display.currentMode)
        if favorites.contains(current) {
            favorites.removeAll { $0 == current }
        } else {
            guard favorites.count < maxFavoritesPerDisplay else {
                lastErrorMessage = "Favorites are limited to \(maxFavoritesPerDisplay) modes per display."
                rebuildMenu()
                return
            }
            favorites.append(current)
        }

        setStoredFavorites(favorites, for: display.id)
        rebuildMenu()
    }

    @objc private func unpinFavorite(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModeSelection else {
            return
        }
        var favorites = storedFavorites(for: selection.displayID)
        let stored = StoredMode(mode: selection.mode)
        favorites.removeAll { $0 == stored }
        setStoredFavorites(favorites, for: selection.displayID)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard isRunningFromAppBundle else {
            lastErrorMessage = "Launch at Login requires QuickRes.app (not swift run)."
            rebuildMenu()
            return
        }

        do {
            if isLaunchAtLoginEnabled() {
                try disableLaunchAtLogin()
            } else {
                try enableLaunchAtLogin()
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = launchAtLoginErrorMessage(for: error)
        }

        rebuildMenu()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Resolution")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Display Resolution Switcher"
        }
    }

    private func makeDisplayItem(_ display: DisplayInfo) -> NSMenuItem {
        let slotSuffix = displaySlotsByDisplayID[display.id].map { " [\($0)]" } ?? ""
        let root = NSMenuItem(title: display.name + slotSuffix, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: display.name)

        let previousItem = NSMenuItem(
            title: titleForPreviousToggle(on: display),
            action: #selector(togglePreviousModeFromMenu(_:)),
            keyEquivalent: ""
        )
        previousItem.target = self
        previousItem.representedObject = DisplaySelection(displayID: display.id)
        previousItem.isEnabled = canTogglePreviousMode(on: display)
        submenu.addItem(previousItem)

        let favorites = favoriteModes(on: display)
        if !favorites.isEmpty {
            addSection("Favorites", modes: favorites, for: display, in: submenu)
        }

        if showAllModes {
            addSection("All Modes", modes: display.modes, for: display, in: submenu)
        } else {
            let groups = curatedGroups(for: display)
            addSection("Recommended", modes: groups.recommended, for: display, in: submenu)
            if !groups.more.isEmpty {
                addSection("More Modes", modes: groups.more, for: display, in: submenu)
            }
        }

        submenu.addItem(.separator())

        let currentStored = StoredMode(mode: display.currentMode)
        let favoriteToggle = NSMenuItem(
            title: currentModeFavoriteTitle(for: display, currentMode: currentStored),
            action: #selector(toggleCurrentModeFavorite(_:)),
            keyEquivalent: ""
        )
        favoriteToggle.target = self
        favoriteToggle.representedObject = DisplaySelection(displayID: display.id)
        if !storedFavorites(for: display.id).contains(currentStored),
           storedFavorites(for: display.id).count >= maxFavoritesPerDisplay {
            favoriteToggle.isEnabled = false
        }
        submenu.addItem(favoriteToggle)

        if !favorites.isEmpty {
            let unpinHeader = NSMenuItem(title: "Unpin Favorite", action: nil, keyEquivalent: "")
            let unpinMenu = NSMenu(title: "Unpin Favorite")
            for mode in favorites {
                let item = NSMenuItem(
                    title: title(for: mode, on: display),
                    action: #selector(unpinFavorite(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ModeSelection(displayID: display.id, mode: mode)
                unpinMenu.addItem(item)
            }
            unpinHeader.submenu = unpinMenu
            submenu.addItem(unpinHeader)
        }

        root.submenu = submenu
        return root
    }

    private func addSection(_ sectionTitle: String, modes: [CGDisplayMode], for display: DisplayInfo, in menu: NSMenu) {
        guard !modes.isEmpty else {
            return
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: sectionTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for mode in modes {
            let item = NSMenuItem(title: title(for: mode, on: display), action: #selector(changeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ModeSelection(displayID: display.id, mode: mode)
            if mode.ioDisplayModeID == display.currentMode.ioDisplayModeID {
                item.state = .on
            }
            menu.addItem(item)
        }
    }

    private func curatedGroups(for display: DisplayInfo) -> (recommended: [CGDisplayMode], more: [CGDisplayMode], legacy: [CGDisplayMode]) {
        let collapsed = collapseDuplicateModes(display.modes)
        let sorted = collapsed.sorted(by: modeSort)

        let hidpi = sorted.filter(isHiDPI)
        let source = hidpi.isEmpty ? sorted : hidpi
        var recommended = Array(source.prefix(6))

        if let current = bestCanonicalMatch(for: display.currentMode, in: sorted) {
            insertIfMissing(current, into: &recommended)
        }
        if let native = nativeMode(from: sorted) {
            insertIfMissing(native, into: &recommended)
        }
        recommended.sort(by: modeSort)

        var leftovers = sorted.filter { mode in
            !recommended.contains(where: { $0.ioDisplayModeID == mode.ioDisplayModeID })
        }

        var legacy = [CGDisplayMode]()
        leftovers.removeAll { mode in
            let isLegacy = isLegacyMode(mode, display: display)
            if isLegacy {
                legacy.append(mode)
            }
            return isLegacy
        }
        legacy.sort(by: modeSort)

        return (recommended, leftovers, legacy)
    }

    private func collapseDuplicateModes(_ modes: [CGDisplayMode]) -> [CGDisplayMode] {
        var bestByKey = [CuratedModeKey: CGDisplayMode]()
        for mode in modes {
            let key = CuratedModeKey(width: mode.width, height: mode.height, isHiDPI: isHiDPI(mode))
            guard let existing = bestByKey[key] else {
                bestByKey[key] = mode
                continue
            }
            if modeSort(mode, existing) {
                bestByKey[key] = mode
            }
        }
        return Array(bestByKey.values)
    }

    private func bestCanonicalMatch(for mode: CGDisplayMode, in list: [CGDisplayMode]) -> CGDisplayMode? {
        let target = CuratedModeKey(width: mode.width, height: mode.height, isHiDPI: isHiDPI(mode))
        return list
            .filter { CuratedModeKey(width: $0.width, height: $0.height, isHiDPI: isHiDPI($0)) == target }
            .max(by: { modeSort($1, $0) })
    }

    private func nativeMode(from modes: [CGDisplayMode]) -> CGDisplayMode? {
        modes.max {
            let leftPixels = $0.pixelWidth * $0.pixelHeight
            let rightPixels = $1.pixelWidth * $1.pixelHeight
            if leftPixels != rightPixels {
                return leftPixels < rightPixels
            }
            return $0.refreshRate < $1.refreshRate
        }
    }

    private func isLegacyMode(_ mode: CGDisplayMode, display: DisplayInfo) -> Bool {
        guard let native = nativeMode(from: display.modes) else {
            return false
        }
        let nativeArea = native.width * native.height
        let modeArea = mode.width * mode.height
        return mode.width < 1280 || mode.height < 800 || Double(modeArea) < Double(nativeArea) * 0.45
    }

    private func modeSort(_ lhs: CGDisplayMode, _ rhs: CGDisplayMode) -> Bool {
        let leftArea = lhs.width * lhs.height
        let rightArea = rhs.width * rhs.height
        if leftArea != rightArea {
            return leftArea > rightArea
        }
        let leftHiDPI = isHiDPI(lhs)
        let rightHiDPI = isHiDPI(rhs)
        if leftHiDPI != rightHiDPI {
            return leftHiDPI
        }
        if lhs.refreshRate != rhs.refreshRate {
            return lhs.refreshRate > rhs.refreshRate
        }
        return lhs.ioDisplayModeID > rhs.ioDisplayModeID
    }

    private func isHiDPI(_ mode: CGDisplayMode) -> Bool {
        mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
    }

    private func insertIfMissing(_ mode: CGDisplayMode, into modes: inout [CGDisplayMode]) {
        if !modes.contains(where: { $0.ioDisplayModeID == mode.ioDisplayModeID }) {
            modes.append(mode)
        }
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    private var launchAtLoginHelpText: String {
        if !isRunningFromAppBundle {
            return "Launch at Login requires QuickRes.app (not swift run)."
        }
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .requiresApproval {
                return "macOS requires approval in System Settings > Login Items."
            }
            if isLaunchAgentEnabled() {
                return "Using fallback startup mode (works outside Applications)."
            }
            return ""
        }
        if isLaunchAgentEnabled() {
            return "Using fallback startup mode."
        }
        return ""
    }

    private var shouldShowLaunchAtLoginHelpText: Bool {
        !launchAtLoginHelpText.isEmpty
    }

    private func makeLaunchAtLoginMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        item.target = self

        guard isRunningFromAppBundle else {
            item.isEnabled = false
            item.state = .off
            return item
        }

        guard #available(macOS 13.0, *) else {
            item.state = isLaunchAgentEnabled() ? .on : .off
            return item
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            item.state = .on
        case .requiresApproval:
            item.state = .mixed
        case .notRegistered, .notFound:
            item.state = isLaunchAgentEnabled() ? .on : .off
        @unknown default:
            item.state = isLaunchAgentEnabled() ? .on : .off
        }

        return item
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                return true
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        }
        return isLaunchAgentEnabled()
    }

    private func enableLaunchAtLogin() throws {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            case .notRegistered:
                do {
                    try SMAppService.mainApp.register()
                    try uninstallLaunchAgent()
                    return
                } catch {
                    let nsError = error as NSError
                    if !shouldUseLaunchAgentFallback(for: nsError) {
                        throw error
                    }
                }
            case .notFound:
                break
            @unknown default:
                break
            }
        }

        try installLaunchAgent()
    }

    private func disableLaunchAtLogin() throws {
        var firstError: Error?

        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                do {
                    try SMAppService.mainApp.unregister()
                } catch {
                    let nsError = error as NSError
                    if nsError.code != Int(kSMErrorJobNotFound) {
                        firstError = error
                    }
                }
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        }

        do {
            try uninstallLaunchAgent()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func shouldUseLaunchAgentFallback(for error: NSError) -> Bool {
        switch error.code {
        case Int(kSMErrorInternalFailure),
             Int(kSMErrorInvalidSignature),
             Int(kSMErrorToolNotValid),
             Int(kSMErrorServiceUnavailable),
             Int(kSMErrorJobPlistNotFound):
            return true
        default:
            return false
        }
    }

    private var launchAgentLabel: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.quickres.app"
        return "\(bundleID).launchagent"
    }

    private var launchAgentPlistURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    private func isLaunchAgentEnabled() -> Bool {
        guard let launchAgentPlistURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    private func installLaunchAgent() throws {
        guard let launchAgentPlistURL else {
            throw NSError(
                domain: "QuickRes",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve LaunchAgents folder."]
            )
        }

        let launchAgentDirectory = launchAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentDirectory, withIntermediateDirectories: true)

        let programArguments = ["/usr/bin/open", "-gj", Bundle.main.bundleURL.path]
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: launchAgentPlistURL, options: .atomic)
    }

    private func uninstallLaunchAgent() throws {
        guard let launchAgentPlistURL else {
            return
        }
        if FileManager.default.fileExists(atPath: launchAgentPlistURL.path) {
            try FileManager.default.removeItem(at: launchAgentPlistURL)
        }
    }

    private func refreshLaunchAgentIfEnabled() throws {
        if isLaunchAgentEnabled() {
            try installLaunchAgent()
        }
    }

    private func launchAtLoginErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case Int(kSMErrorAlreadyRegistered):
            return "Launch at Login is already enabled."
        case Int(kSMErrorJobNotFound):
            return "Launch at Login is already disabled."
        case Int(kSMErrorLaunchDeniedByUser):
            return "Launch at Login permission was denied in System Settings."
        case Int(kSMErrorInvalidSignature):
            return "QuickRes.app signature is invalid. Reinstall the app and try again."
        case Int(kSMErrorInvalidPlist):
            return "QuickRes app bundle is invalid. Reinstall the app and try again."
        default:
            break
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "Failed to update Launch at Login."
        }
        return "Failed to update Launch at Login: \(message)"
    }

    private func storageKey(for displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }

    private func storedFavorites(for displayID: CGDirectDisplayID) -> [StoredMode] {
        favoritesByDisplay[storageKey(for: displayID)] ?? []
    }

    private func setStoredFavorites(_ favorites: [StoredMode], for displayID: CGDirectDisplayID) {
        var normalized = [StoredMode]()
        for favorite in favorites where !normalized.contains(favorite) {
            normalized.append(favorite)
        }
        if normalized.count > maxFavoritesPerDisplay {
            normalized = Array(normalized.prefix(maxFavoritesPerDisplay))
        }
        favoritesByDisplay[storageKey(for: displayID)] = normalized
        persistFavorites()
    }

    private func setPreviousMode(_ mode: StoredMode, for displayID: CGDirectDisplayID) {
        previousModeByDisplay[storageKey(for: displayID)] = mode
        persistPreviousModes()
    }

    private func previousMode(for displayID: CGDirectDisplayID) -> StoredMode? {
        previousModeByDisplay[storageKey(for: displayID)]
    }

    private func resolvedMode(for storedMode: StoredMode, on display: DisplayInfo) -> CGDisplayMode? {
        if let exact = display.modes.first(where: { storedMode.matches($0) }) {
            return exact
        }

        return display.modes
            .filter {
                $0.width == storedMode.width &&
                    $0.height == storedMode.height &&
                    isHiDPI($0) == storedMode.isHiDPI
            }
            .max(by: { modeSort($1, $0) })
    }

    private func favoriteModes(on display: DisplayInfo) -> [CGDisplayMode] {
        let stored = storedFavorites(for: display.id)
        var resolved = [CGDisplayMode]()
        var normalizedStored = [StoredMode]()

        for favorite in stored {
            guard let mode = resolvedMode(for: favorite, on: display) else {
                continue
            }
            if resolved.contains(where: { $0.ioDisplayModeID == mode.ioDisplayModeID }) {
                continue
            }
            resolved.append(mode)
            normalizedStored.append(StoredMode(mode: mode))
        }

        if normalizedStored != stored {
            setStoredFavorites(normalizedStored, for: display.id)
        }
        return resolved
    }

    private func applyModeChange(on display: DisplayInfo, to mode: CGDisplayMode) {
        guard mode.ioDisplayModeID != display.currentMode.ioDisplayModeID else {
            return
        }

        let current = StoredMode(mode: display.currentMode)
        do {
            try displayManager.setDisplayMode(displayID: display.id, mode: mode)
            setPreviousMode(current, for: display.id)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        rebuildMenu()
    }

    private func canTogglePreviousMode(on display: DisplayInfo) -> Bool {
        guard let previous = previousMode(for: display.id),
              let mode = resolvedMode(for: previous, on: display) else {
            return false
        }
        return mode.ioDisplayModeID != display.currentMode.ioDisplayModeID
    }

    private func titleForPreviousToggle(on display: DisplayInfo) -> String {
        guard let previous = previousMode(for: display.id),
              let mode = resolvedMode(for: previous, on: display) else {
            return "Previous Mode (Unavailable)"
        }
        return "Previous Mode: \(title(for: mode, on: display))"
    }

    private func togglePreviousMode(on display: DisplayInfo) {
        guard let previous = previousMode(for: display.id),
              let mode = resolvedMode(for: previous, on: display) else {
            lastErrorMessage = "No previous mode found for \(display.name)."
            rebuildMenu()
            return
        }
        applyModeChange(on: display, to: mode)
    }

    private func currentModeFavoriteTitle(for display: DisplayInfo, currentMode: StoredMode) -> String {
        let favorites = storedFavorites(for: display.id)
        if favorites.contains(currentMode) {
            return "Unpin Current Mode from Favorites"
        }
        if favorites.count >= maxFavoritesPerDisplay {
            return "Pin Current Mode to Favorites (Max \(maxFavoritesPerDisplay))"
        }
        return "Pin Current Mode to Favorites"
    }

    private func loadPersistedSettings() {
        if let data = defaults.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([String: [StoredMode]].self, from: data) {
            favoritesByDisplay = decoded
            for (key, favorites) in decoded {
                favoritesByDisplay[key] = Array(favorites.prefix(maxFavoritesPerDisplay))
            }
        }

        if let data = defaults.data(forKey: previousModeKey),
           let decoded = try? JSONDecoder().decode([String: StoredMode].self, from: data) {
            previousModeByDisplay = decoded
        }
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(favoritesByDisplay) else {
            return
        }
        defaults.set(data, forKey: favoritesKey)
    }

    private func persistPreviousModes() {
        guard let data = try? JSONEncoder().encode(previousModeByDisplay) else {
            return
        }
        defaults.set(data, forKey: previousModeKey)
    }

    private func registerHotKeys() {
        if hotKeyHandlerRef == nil {
            var eventSpec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                Self.hotKeyHandler,
                1,
                &eventSpec,
                nil,
                &hotKeyHandlerRef
            )
        }

        unregisterRegisteredHotKeys()

        for slot in 1...9 {
            guard let keyCode = hotKeyKeyCodes[slot] else {
                continue
            }

            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: UInt32(slot))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                UInt32(cmdKey | optionKey | controlKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs[slot] = hotKeyRef
            }
        }
    }

    private func unregisterRegisteredHotKeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func unregisterHotKeys() {
        unregisterRegisteredHotKeys()
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func handlePreviousModeHotKey(slot: Int) {
        guard let displayID = displaySlotsByNumber[slot],
              let display = displaysByID[displayID] else {
            NSSound.beep()
            return
        }
        togglePreviousMode(on: display)
    }

    private func shouldConfirmRiskyMode(_ mode: CGDisplayMode, on display: DisplayInfo) -> Bool {
        let builtIn = CGDisplayIsBuiltin(display.id) != 0
        if builtIn && !isHiDPI(mode) {
            return true
        }
        return isLegacyMode(mode, display: display)
    }

    private func confirmRiskySwitch(mode: CGDisplayMode, display: DisplayInfo) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This mode may reduce visual quality"
        alert.informativeText = "Switch \(display.name) to \(title(for: mode, on: display))?"
        alert.addButton(withTitle: "Switch Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func riskWasAcknowledged(displayID: CGDirectDisplayID, mode: CGDisplayMode) -> Bool {
        defaults.bool(forKey: riskKey(displayID: displayID, mode: mode))
    }

    private func acknowledgeRisk(displayID: CGDirectDisplayID, mode: CGDisplayMode) {
        defaults.set(true, forKey: riskKey(displayID: displayID, mode: mode))
    }

    private func riskKey(displayID: CGDirectDisplayID, mode: CGDisplayMode) -> String {
        "\(riskAckPrefix).\(displayID).\(mode.ioDisplayModeID)"
    }

    private func title(for mode: CGDisplayMode, on display: DisplayInfo) -> String {
        let refreshText: String
        if mode.refreshRate > 0 {
            if abs(mode.refreshRate.rounded() - mode.refreshRate) < 0.01 {
                refreshText = "@ \(Int(mode.refreshRate.rounded()))Hz"
            } else {
                refreshText = String(format: "@ %.2fHz", mode.refreshRate)
            }
        } else {
            refreshText = ""
        }

        var suffixes = [String]()
        if isHiDPI(mode) {
            suffixes.append("HiDPI")
        } else {
            suffixes.append("Low resolution")
        }
        if isLegacyMode(mode, display: display) {
            suffixes.append("Legacy")
        }

        let suffix = suffixes.isEmpty ? "" : " (" + suffixes.joined(separator: ", ") + ")"
        return "\(mode.width) x \(mode.height) \(refreshText)\(suffix)".trimmingCharacters(in: .whitespaces)
    }

    private func installObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMenu),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(rebuildMenu),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

@main
@MainActor
struct ResolutionSwitcherApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
