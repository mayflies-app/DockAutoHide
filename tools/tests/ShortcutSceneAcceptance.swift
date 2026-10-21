import AppKit
import Foundation

// Compile the unchanged product App scene and delegate against inert services.
@MainActor final class DockManager {
  init() { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Fixture.inspect() } }
  func restoreManualAutoHideOnQuit() {}
}
@MainActor final class LaunchAtLoginManager {}
@MainActor final class MenuBarManager {
  init(dockManager: DockManager, launchAtLoginManager: LaunchAtLoginManager) {}
}
@MainActor enum Fixture {
  static var report: [String: Any] = ["boundary": "unchanged product App/Settings scene + delegate; inert Dock/login/status services", "dockMutations": 0, "loginMutations": 0]
  static func items(_ menu: NSMenu?) -> [NSMenuItem] {
    guard let menu else { return [] }
    return menu.items.flatMap { [$0] + items($0.submenu) }
  }
  static func inspect() {
    let all = items(NSApp.mainMenu)
    report["menu"] = all.map { ["title": $0.title, "key": $0.keyEquivalent, "modifiers": $0.keyEquivalentModifierMask.rawValue, "action": $0.action.map(NSStringFromSelector) ?? "", "enabled": $0.isEnabled] as [String: Any] }
    report["windowsBefore"] = NSApp.windows.map { ["title": $0.title, "visible": $0.isVisible] }
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
    let commaDispatched = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    report["commandCommaDispatched"] = commaDispatched
    report["settingsCommands"] = all.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }.count
    report["hadMainMenu"] = NSApp.mainMenu != nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      report["windowsAfter"] = NSApp.windows.map { ["title": $0.title, "visible": $0.isVisible, "key": $0.isKeyWindow, "contentWidth": $0.contentView?.frame.width ?? -1, "contentHeight": $0.contentView?.frame.height ?? -1] }
      report["passed"] = NSApp.mainMenu != nil && !commaDispatched
        && !all.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
        && NSApp.windows.isEmpty
      let url = URL(fileURLWithPath: CommandLine.arguments[1])
      try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
      NSApp.terminate(nil)
    }
  }
}
