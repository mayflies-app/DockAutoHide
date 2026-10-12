import AppKit
import ApplicationServices
import Foundation
import Darwin

// This verifier acts only on the observed status icon and language submenu.
// SIGINT/SIGTERM interrupt acceptance, then take the same restoration path as failures.
var interrupted: Int32 = 0
func receiveSignal(_ value: Int32) { interrupted = value }
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
let identifier = "app.mayfiles.DockAutoHide"
let languageKey = "DockAutoHide.language"
let fm = FileManager.default
func canonical(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() }
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func elements(_ value: CFTypeRef?) -> [AXUIElement] {
    guard let value else { return [] }
    if CFGetTypeID(value) == AXUIElementGetTypeID() { return [value as! AXUIElement] }
    return value as? [AXUIElement] ?? []
}
func text(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func actions(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    return AXUIElementCopyActionNames(element, &value) == .success ? value as? [String] ?? [] : []
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(element, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
struct Node {
    let element: AXUIElement; let path: String
    var role: String { text(element, "AXRole") }
    var title: String { text(element, "AXTitle") }
    var label: String { title.isEmpty ? text(element, "AXDescription") : title }
    var visible: Bool { frame(element).map { $0.width > 0 && $0.height > 0 } ?? false }
    var checked: Bool { !text(element, "AXMenuItemMarkChar").isEmpty }
    var json: [String: Any] {
        var result: [String: Any] = ["path": path, "role": role, "title": title, "description": text(element, "AXDescription"), "actions": actions(element), "visible": visible, "checked": checked]
        if let rect = frame(element) { result["frame"] = [rect.minX, rect.minY, rect.width, rect.height] }
        if let value = attribute(element, "AXEnabled") as? NSNumber { result["enabled"] = value }
        return result
    }
}
func inspect(_ root: AXUIElement) -> [Node] {
    var result: [Node] = []; var visited = Set<CFHashCode>()
    func walk(_ element: AXUIElement, path: String, depth: Int) {
        guard depth < 12, result.count < 180, visited.insert(CFHash(element)).inserted else { return }
        result.append(Node(element: element, path: path))
        for name in depth == 0 ? ["AXExtrasMenuBar"] : ["AXChildren"] {
            for (index, child) in elements(attribute(element, name)).enumerated() {
                walk(child, path: path + "/" + name + "/" + String(index), depth: depth + 1)
            }
        }
    }
    walk(root, path: "app", depth: 0)
    return result
}
func domain(_ name: String) -> [String: Any] {
    _ = CFPreferencesAppSynchronize(name as CFString)
    return CFPreferencesCopyMultiple(nil, name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
}
func same(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool { NSDictionary(dictionary: lhs).isEqual(to: rhs) }
func dockConfiguration(_ values: [String: Any]) -> [String: Any] {
    // macOS increments this bookkeeping counter when Dock preferences synchronize.
    // Keep it in snapshots, but do not treat it as a user setting or rewrite it.
    values.filter { $0.key != "mod-count" }
}
func pidExists(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH // Unknown access errors do not establish termination.
}
func liveApplications() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { pidExists($0.processIdentifier) }
}
func saveJSON(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
}
func savePreferences(_ value: [String: Any], _ url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
}
struct Options {
    let app: URL; let output: URL; let timeout: Double
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst()); var values: [String: String] = [:]; var index = 0
        while index < args.count {
            let key = args[index]
            guard ["--app", "--output", "--timeout-seconds"].contains(key), index + 1 < args.count, values[key] == nil else { throw Failure("Invalid or duplicate verifier argument") }
            values[key] = args[index + 1]; index += 2
        }
        guard let path = values["--app"], path.hasPrefix("/"), let out = values["--output"], out.hasPrefix("/"),
              let timeout = Double(values["--timeout-seconds"] ?? "120"), timeout.isFinite, timeout > 0, timeout <= 86400 else { throw Failure("Required absolute --app, --output and positive timeout") }
        app = canonical(path); output = canonical(out); self.timeout = timeout
        guard Bundle(url: app)?.bundleIdentifier == identifier,
              Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "DockAutoHide",
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/DockAutoHide").path) else { throw Failure("Not a DockAutoHide app bundle") }
    }
}
final class Acceptance {
    let options: Options
    var deadline: Date
    var restoring = false
    var originalProcess: NSRunningApplication?
    var process: NSRunningApplication?
    var originalSettings: [String: Any] = [:]
    var originalDockSettings: [String: Any] = [:]
    var originalLanguage: String?
    var capturedSettings = false
    var languageTouched = false
    var actionsLog: [[String: Any]] = []
    var terminationObservations: [[String: Any]] = []
    var mouseButtonObservations: [[String: Any]] = []
    var checks: [[String: Any]] = []
    var errors: [String] = []
    var restored = false
    var uiLanguageRestored = false
    var runningRestored = false
    var pid: pid_t?
    init(_ options: Options) { self.options = options; deadline = Date().addingTimeInterval(options.timeout) }
    func checkDeadline() throws {
        guard Date() < deadline else { throw Failure(restoring ? "Restoration deadline exceeded" : "Acceptance deadline exceeded") }
        if !restoring, interrupted != 0 { throw Failure("Interrupted by signal \(interrupted)") }
    }
    func pause(_ seconds: Double = 0.1) throws { try checkDeadline(); RunLoop.current.run(until: Date().addingTimeInterval(seconds)); try checkDeadline() }
    func wait(_ reason: String, seconds: Double = 5, until condition: () -> Bool) throws {
        let limit = min(deadline, Date().addingTimeInterval(seconds))
        while !condition() { guard Date() < limit else { throw Failure(reason) }; try pause() }
    }
    func verified(_ application: NSRunningApplication) throws {
        guard !application.isTerminated, pidExists(application.processIdentifier), application.bundleIdentifier == identifier,
              application.bundleURL.map({ canonical($0.path) }) == options.app,
              application.executableURL.map({ canonical($0.path) }) == options.app.appendingPathComponent("Contents/MacOS/DockAutoHide") else { throw Failure("App PID/path/executable identity changed") }
        let matches = liveApplications()
        guard matches.count == 1, matches[0].processIdentifier == application.processIdentifier else { throw Failure("Foreign or multiple same-identifier apps are running") }
    }
    func root() throws -> AXUIElement {
        try checkDeadline()
        guard let process else { throw Failure("No verified app process") }; try verified(process)
        let root = AXUIElementCreateApplication(process.processIdentifier); _ = AXUIElementSetMessagingTimeout(root, 2)
        return root
    }
    func nodes() throws -> [Node] { inspect(try root()) }
    func visibleLanguages(_ nodes: [Node]) -> [Node] { nodes.filter { $0.role == "AXMenuItem" && ["English", "简体中文"].contains($0.title) && $0.visible } }
    func clickStatus() throws {
        let nodes = try self.nodes()
        guard let node = nodes.first(where: { $0.role == "AXMenuBarItem" && ["Dock Auto Hide", "Dock 自动隐藏"].contains($0.label) }),
              let rect = frame(node.element), rect.width > 0, rect.height > 0, rect.width <= 48, rect.height <= 48 else { throw Failure("No observed DockAutoHide status-icon frame") }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard point.x.isFinite, point.y.isFinite, let source = CGEventSource(stateID: .combinedSessionState) else { throw Failure("Invalid status-icon click") }
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw Failure("Cannot create paired status-icon events") }
        move.post(tap: .cghidEventTap); try pause(0.05)
        func clickPair() {
            down.post(tap: .cghidEventTap)
            // No throwing/deadline work may bypass the matching release event.
            defer { up.post(tap: .cghidEventTap) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            mouseButtonObservations.append(["phase": "after-owned-down", "leftButtonDown": CGEventSource.buttonState(.combinedSessionState, button: .left)])
            if ProcessInfo.processInfo.environment["DOCK_LOCALIZATION_TEST_INTERRUPT_AFTER_MOUSE_DOWN"] == "1" { raise(SIGTERM) }
        }
        clickPair()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        mouseButtonObservations.append(["phase": "after-matching-up", "leftButtonDown": CGEventSource.buttonState(.combinedSessionState, button: .left)])
        actionsLog.append(["pid": process!.processIdentifier, "label": node.label, "action": "click observed status-icon frame", "center": [point.x, point.y]])
        try pause(0.3)
    }
    func press(_ node: Node) throws {
        _ = try root()
        guard node.visible, node.role == "AXMenuItem", ["Interface Language", "界面语言", "English", "简体中文"].contains(node.title), actions(node.element).contains("AXPress") else { throw Failure("Refused action outside visible language submenu") }
        let result = AXUIElementPerformAction(node.element, "AXPress" as CFString)
        actionsLog.append(["pid": process!.processIdentifier, "label": node.title, "action": "AXPress", "result": result.rawValue])
        guard result == .success else { throw Failure("Language AXPress failed: \(result.rawValue)") }; try pause(0.2)
    }
    func openLanguageMenu() throws -> [Node] {
        var current = try nodes()
        if visibleLanguages(current).count == 2 { return current }
        let openingDeadline = min(deadline, Date().addingTimeInterval(10))
        var nextClick = Date.distantPast; var attempts = 0
        while !current.contains(where: { $0.role == "AXMenu" && $0.visible }) {
            guard Date() < openingDeadline else {
                try? saveJSON(["pid": process!.processIdentifier, "attempts": attempts, "nodes": current.map(\.json)], options.output.appendingPathComponent("menu-opening-failure.json"))
                throw Failure("Status menu did not become visible after \(attempts) observed-frame clicks")
            }
            if Date() >= nextClick, attempts < 4 {
                // Startup authorization/frontmost restoration may close a tracking menu.
                // Retry only when a fresh AX observation establishes that it is closed.
                try clickStatus(); attempts += 1; nextClick = Date().addingTimeInterval(1.5)
            }
            try pause(0.15); current = try nodes()
        }
        current = try nodes()
        guard let parent = current.first(where: { $0.role == "AXMenuItem" && ["Interface Language", "界面语言"].contains($0.title) && $0.visible }) else { throw Failure("Visible language menu row missing") }
        try press(parent)
        try wait("Language submenu did not become visible") { (try? self.visibleLanguages(self.nodes()).count) == 2 }
        return try nodes()
    }
    func dismissLanguageMenu() throws {
        let current = try nodes()
        guard let menu = current.first(where: { $0.role == "AXMenu" && $0.visible }) else { return }
        _ = try root()
        guard actions(menu.element).contains("AXCancel") else { throw Failure("Observed app menu has no cancel action") }
        let result = AXUIElementPerformAction(menu.element, "AXCancel" as CFString)
        actionsLog.append(["pid": process!.processIdentifier, "role": menu.role, "path": menu.path, "action": "AXCancel", "result": result.rawValue])
        guard result == .success else { throw Failure("Observed app menu cancellation failed: \(result.rawValue)") }
        try wait("Observed app menu did not close", seconds: 3) {
            (try? self.nodes().contains(where: { $0.role == "AXMenu" && $0.visible })) == false
        }
    }
    func selectedLanguage(_ nodes: [Node]) throws -> String {
        let choices = visibleLanguages(nodes).filter(\.checked)
        guard choices.count == 1 else { throw Failure("Language submenu must have exactly one visible selected choice") }
        return choices[0].title == "English" ? "en" : "zh-Hans"
    }
    func select(_ language: String) throws {
        // Reopening the observed app-owned menu avoids retained tracking state.
        try dismissLanguageMenu()
        let current = try openLanguageMenu()
        let title = language == "en" ? "English" : "简体中文"
        guard let choice = current.first(where: { $0.role == "AXMenuItem" && $0.title == title && $0.visible }) else { throw Failure("Visible language choice missing") }
        languageTouched = true
        try press(choice)
        try dismissLanguageMenu()
        do {
            try wait("Visible menu selection did not update") {
                guard let nodes = try? self.openLanguageMenu() else { return false }
                return (try? self.selectedLanguage(nodes)) == language
            }
        } catch {
            if let observed = try? nodes() {
                try? saveJSON(["pid": process!.processIdentifier, "expectedLanguage": language, "restoring": restoring, "nodes": observed.map(\.json)], options.output.appendingPathComponent("selection-failure.json"))
            }
            throw error
        }
    }
    func capture(_ name: String, language: String) throws {
        let current = try openLanguageMenu()
        let expected = language == "en" ? ["Smart Switching", "Dock Auto-Hide", "Launch at Login", "Interface Language", "Quit"] : ["智能切换", "自动隐藏 Dock", "登录时启动", "界面语言", "退出"]
        let other = language == "en" ? ["智能切换", "自动隐藏 Dock", "登录时启动", "界面语言", "退出"] : ["Smart Switching", "Dock Auto-Hide", "Launch at Login", "Interface Language", "Quit"]
        let visible = current.filter { $0.role == "AXMenuItem" && $0.visible }
        for title in expected {
            guard visible.contains(where: { $0.title == title }) else { throw Failure("Expected visible menu row missing: \(title)") }
            checks.append(["name": name + ": " + title, "passed": true])
        }
        guard !visible.contains(where: { other.contains($0.title) }), try selectedLanguage(current) == language,
              current.contains(where: { $0.role == "AXMenuBarItem" && $0.label == (language == "en" ? "Dock Auto Hide" : "Dock 自动隐藏") }) else { throw Failure("Stale translation, incorrect checkmark or status accessibility label") }
        let prefix = language == "en" ? "Status: " : "状态："
        let version = language == "en" ? "Version: v" : "版本：v"
        guard visible.contains(where: { $0.title.hasPrefix(prefix) }), visible.contains(where: { $0.title.hasPrefix(version) }) else { throw Failure("Localized status/version row missing") }
        try saveJSON(["pid": process!.processIdentifier, "language": language, "nodes": current.map(\.json)], options.output.appendingPathComponent(name + ".json"))
        let menus = current.filter { $0.role == "AXMenu" && $0.visible }.compactMap { frame($0.element) }
        guard let first = menus.first else { throw Failure("No visible menu region for screenshot") }
        let axRegion = menus.dropFirst().reduce(first) { $0.union($1) }
        // AX/WindowServer publish final popup bounds before AppKit finishes its
        // content animation. Let that compositor transition finish before capture.
        try pause(0.5)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var observedWindows: [[String: Any]] = []; var popupFrames: [CGRect] = []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process!.processIdentifier,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { continue }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            observedWindows.append(["windowID": window[kCGWindowNumber as String] as Any? ?? NSNull(), "layer": layer, "bounds": [rect.minX, rect.minY, rect.width, rect.height]])
            // Menus are elevated popup windows; exclude normal app windows and the
            // small status icon, and require proximity to the observed AX menus.
            if layer > 0, rect.width > 48, rect.height > 40, rect.intersects(axRegion.insetBy(dx: -48, dy: -48)) { popupFrames.append(rect) }
        }
        guard let popup = popupFrames.first else { throw Failure("No app-owned onscreen popup geometry available for complete menu screenshot") }
        let region = popupFrames.dropFirst().reduce(popup) { $0.union($1) }.insetBy(dx: -5, dy: -5)
        try saveJSON(["pid": process!.processIdentifier, "method": "union of exact app-owned elevated onscreen popup window bounds near observed AX menus", "AXMenuBounds": [axRegion.minX, axRegion.minY, axRegion.width, axRegion.height], "captureBounds": [region.minX, region.minY, region.width, region.height], "compositorSettleSeconds": 0.5, "ownedOnscreenWindows": observedWindows], options.output.appendingPathComponent(name + "-capture.json"))
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", options.output.appendingPathComponent(name + ".png").path]
        try capture.run()
        do { try wait("Menu screenshot command timed out", seconds: 5) { !capture.isRunning } }
        catch {
            if capture.isRunning {
                capture.terminate()
                // Drain only this owned screenshot command before UI restoration.
                // Ignore the acceptance signal here so cleanup cannot race its exit.
                let stopDeadline = Date().addingTimeInterval(2)
                while capture.isRunning && Date() < stopDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            throw error
        }
        guard capture.terminationStatus == 0, fm.fileExists(atPath: options.output.appendingPathComponent(name + ".png").path) else { throw Failure("Menu screenshot failed; existing Screen Recording access is required") }
        checks.append(["name": name + ": actual menu, checkmark, accessibility label, status, version and screenshot", "passed": true, "pid": process!.processIdentifier])
        print("PASS \(name): visible bilingual menu in PID \(process!.processIdentifier)")
    }
    func start() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess() else { throw Failure("Existing Accessibility, event-posting and Screen Recording permissions are required; no permission requests are made") }
        let candidates = liveApplications()
        guard candidates.count <= 1 else { throw Failure("Multiple same-identifier apps are running") }
        if let existing = candidates.first { try verified(existing); originalProcess = existing; process = existing }
        originalSettings = domain(identifier); originalDockSettings = domain("com.apple.dock"); capturedSettings = true
        try savePreferences(originalSettings, options.output.appendingPathComponent("preferences-before.plist"))
        try savePreferences(originalDockSettings, options.output.appendingPathComponent("dock-preferences-before.plist"))
        if process == nil {
            guard let manual = originalSettings["DockAutoHide.manualAutoHideEnabled"] as? NSNumber,
                  CFGetTypeID(manual) == CFBooleanGetTypeID(),
                  let actual = originalDockSettings["autohide"] as? NSNumber,
                  CFGetTypeID(actual) == CFBooleanGetTypeID(), manual.boolValue == actual.boolValue else {
                throw Failure("Automatic test launch requires a saved manual Dock setting matching the current Dock auto-hide setting; complete normal first-launch setup and launch the app before testing")
            }
            var completed = false; var launchError: Error?
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            NSWorkspace.shared.openApplication(at: options.app, configuration: configuration) { application, error in
                self.process = application; launchError = error; completed = true
            }
            try wait("App launch timed out", seconds: 15) { completed }
            if let launchError { throw launchError }
        }
        guard let process else { throw Failure("App launch returned no process") }; try verified(process); pid = process.processIdentifier
        try wait("Status icon did not appear", seconds: 10) { (try? self.nodes().contains(where: { $0.role == "AXMenuBarItem" && ["Dock Auto Hide", "Dock 自动隐藏"].contains($0.label) })) ?? false }
        if originalProcess == nil { try pause(2) } // Let normal startup authorization/frontmost restoration settle.
        originalLanguage = try selectedLanguage(openLanguageMenu())
    }
    func run() throws {
        try start()
        guard let originalLanguage else { throw Failure("Original language not captured") }
        // Always cross a language boundary first, including when originally English.
        let order = originalLanguage == "en" ? ["zh-Hans", "en"] : ["en", "zh-Hans"]
        for (index, language) in order.enumerated() {
            try select(language); try capture("menu-" + language, language: language)
            // Selecting the original effective language may retain an absent original key.
            let observed = domain(identifier)
            guard same(observed.filter { $0.key != languageKey }, originalSettings.filter { $0.key != languageKey }) else { throw Failure("A non-language app setting changed") }
            guard observed[languageKey] as? String == language else { throw Failure("Explicit language selection was not persisted") }
            if index == 0, ProcessInfo.processInfo.environment["DOCK_LOCALIZATION_TEST_INTERRUPT_AFTER_FIRST_LANGUAGE"] == "1" { raise(SIGTERM); try checkDeadline() }
            if index == 0, ProcessInfo.processInfo.environment["DOCK_LOCALIZATION_TEST_FAIL_AFTER_FIRST_LANGUAGE"] == "1" { throw Failure("Injected failure after first real language selection") }
        }
        guard let process, process.processIdentifier == pid else { throw Failure("App restarted during language verification") }
        try verified(process)
    }
    func cleanup() {
        restoring = true; deadline = Date().addingTimeInterval(55)
        uiLanguageRestored = !languageTouched
        do {
            if capturedSettings {
                if process == nil {
                    let matches = liveApplications()
                    if matches.count == 1 { try verified(matches[0]); process = matches[0] }
                }
                // An early interrupted status click can leave tracking open before
                // any language was selected; cancel only this observed app-owned menu.
                if let process, !process.isTerminated, pidExists(process.processIdentifier) { try dismissLanguageMenu() }
                if let process, !process.isTerminated, let originalLanguage, languageTouched {
                    try select(originalLanguage)
                    // Selecting a checked language also closes tracking without a policy action.
                    let currentMenu = try openLanguageMenu()
                    guard let selected = visibleLanguages(currentMenu).first(where: \.checked) else { throw Failure("Restored language row missing") }
                    try press(selected)
                    uiLanguageRestored = true
                }
            }
        } catch { errors.append("Language UI restoration failed: \(error)") }
        // A missing/closed menu must not prevent restoring the one persisted key.
        // This independent attempt never replaces the complete preference domain.
        if capturedSettings, languageTouched {
            do {
                let current = domain(identifier)
                let originalValue = originalSettings[languageKey]
                let currentValue = current[languageKey]
                if !NSDictionary(dictionary: ["value": currentValue ?? NSNull()]).isEqual(to: ["value": originalValue ?? NSNull()]) {
                    CFPreferencesSetAppValue(languageKey as CFString, originalValue.map { $0 as CFPropertyList }, identifier as CFString)
                    guard CFPreferencesAppSynchronize(identifier as CFString) else { throw Failure("Original language persistence could not be restored") }
                }
            } catch { errors.append("Language-key restoration failed: \(error)") }
        }
        do {
            if originalProcess == nil, let process, !process.isTerminated {
                try verified(process)
                guard process.terminate() else { throw Failure("App refused normal termination") }
                var nextObservation = Date.distantPast
                try wait("App did not exit after normal termination; no force kill attempted", seconds: 30) {
                    let fresh = NSRunningApplication(processIdentifier: process.processIdentifier)
                    let exists = pidExists(process.processIdentifier)
                    if Date() >= nextObservation || !exists {
                        self.terminationObservations.append([
                            "pid": process.processIdentifier, "time": Date().timeIntervalSince1970,
                            "pidExists": exists, "cachedTerminated": process.isTerminated,
                            "freshTerminated": fresh?.isTerminated as Any? ?? NSNull(),
                            "freshBundlePath": fresh?.bundleURL?.path as Any? ?? NSNull()
                        ])
                        nextObservation = Date().addingTimeInterval(1)
                    }
                    return !exists
                }
            }
            let matches = liveApplications()
            runningRestored = originalProcess.map { original in matches.count == 1 && matches[0].processIdentifier == original.processIdentifier && !original.isTerminated } ?? matches.isEmpty
            if !runningRestored { errors.append("Original running state was not restored") }
        } catch { errors.append("Running-state restoration failed: \(error)") }
        if capturedSettings {
            let after = domain(identifier); let dockAfter = domain("com.apple.dock")
            restored = same(originalSettings, after) && same(dockConfiguration(originalDockSettings), dockConfiguration(dockAfter))
            do {
                try savePreferences(after, options.output.appendingPathComponent("preferences-after.plist"))
                try savePreferences(dockAfter, options.output.appendingPathComponent("dock-preferences-after.plist"))
            } catch { errors.append("Restoration snapshots failed: \(error)") }
            if !restored { errors.append("App or Dock preferences differ from the original snapshot; no non-language preference overwrite attempted") }
        }
    }
    func report() -> [String: Any] {
        ["passed": errors.isEmpty && restored && uiLanguageRestored && runningRestored && checks.count == 12,
         "method": "real prebuilt app; observed AXExtrasMenuBar, frame-verified CGEvent click, visible language AXPress and screenshots",
         "pid": pid as Any? ?? NSNull(), "checks": checks, "errors": errors, "actions": actionsLog,
         "terminationObservations": terminationObservations, "mouseButtonObservations": mouseButtonObservations, "dockPreferenceComparisonExcludedKeys": ["mod-count"],
         "settingsRestored": restored, "uiLanguageRestored": uiLanguageRestored, "runningStateRestored": runningRestored,
         "originallyRunning": originalProcess != nil, "originalLanguage": originalLanguage as Any? ?? NSNull(),
         "originalLanguageKeyPresent": originalSettings[languageKey] != nil, "signal": interrupted,
         "boundaries": ["permissionRequests": false, "loginItemMutations": false, "dockControlActions": false, "forceKill": false, "sourceChanges": false]]
    }
}

signal(SIGINT, receiveSignal); signal(SIGTERM, receiveSignal)
do {
    let options = try Options(); let test = Acceptance(options)
    do { try test.run() } catch { test.errors.append(String(describing: error)) }
    test.cleanup()
    let report = test.report(); try saveJSON(report, options.output.appendingPathComponent("localization-flow.json"))
    for error in test.errors { fputs("FAIL \(error)\n", stderr) }
    print("Restoration: settings=\(test.restored), runningState=\(test.runningRestored)")
    exit(report["passed"] as? Bool == true ? 0 : 1)
} catch { fputs("LocalizationMenuAcceptance: \(error)\n", stderr); exit(1) }
