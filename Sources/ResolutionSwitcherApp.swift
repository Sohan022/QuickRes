import AppKit
import CoreGraphics
import Foundation

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
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let displayManager = DisplayManager()
    private let defaults = UserDefaults.standard
    private let showAllModesKey = "showAllModesAdvanced"
    private let riskAckPrefix = "riskAcknowledged"
    private var lastErrorMessage: String?
    private var displaysByID = [CGDirectDisplayID: DisplayInfo]()

    private var showAllModes: Bool {
        get { defaults.bool(forKey: showAllModesKey) }
        set { defaults.set(newValue, forKey: showAllModesKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        installObservers()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

        do {
            try displayManager.setDisplayMode(displayID: selection.displayID, mode: selection.mode)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleShowAllModes(_ sender: NSMenuItem) {
        showAllModes.toggle()
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
        let root = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: display.name)

        if showAllModes {
            addSection("All Modes", modes: display.modes, for: display, in: submenu)
        } else {
            let groups = curatedGroups(for: display)
            addSection("Recommended", modes: groups.recommended, for: display, in: submenu)
            if !groups.more.isEmpty {
                addSection("More Modes", modes: groups.more, for: display, in: submenu)
            }
            if !groups.legacy.isEmpty {
                addSection("Legacy / Low Resolution", modes: groups.legacy, for: display, in: submenu)
            }
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
