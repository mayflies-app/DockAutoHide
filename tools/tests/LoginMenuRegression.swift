import AppKit
import Combine
import Foundation

/// Isolated menu boundary: no real Dock manager, status bar, or login service.
@MainActor final class DockManager: ObservableObject {
  var isAuthorized = true
  var smartEnabled = false
  var manualAutoHideEnabled = false
  var currentAutoHideEnabled = false
  var lastErrorMessage: String?
  var policyMutations = 0
  var permissionRequests = 0
  func setSmartEnabled(_ enabled: Bool) { policyMutations += 1; smartEnabled = enabled }
  func setManualAutoHideEnabled(_ enabled: Bool) { policyMutations += 1; manualAutoHideEnabled = enabled }
  func requestAuthorizationFromUser() { permissionRequests += 1 }
}

@MainActor private final class MenuLoginService: LaunchAtLoginService {
  var status: LaunchAtLoginStatus = .notRegistered
  var mutations = 0
  func readStatus() -> LaunchAtLoginStatus { status }
  func register() throws {
    mutations += 1
    throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture login failure"])
  }
  func unregister() throws { mutations += 1 }
  func openSettings() { mutations += 1 }
}

// Exercise the production quit action, but cancel termination in this fixture.
@MainActor private final class QuitProbe: NSObject, NSApplicationDelegate {
  var requests = 0
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    requests += 1
    return .terminateCancel
  }
}

@main private enum LoginMenuRegression {
  @MainActor static func main() {
    // AppKit resolves menu targets through a test-only application context.
    // Prohibited activation creates no Dock icon or windows; the real app never runs.
    NSApplication.shared.setActivationPolicy(.prohibited)
    DockLogger.isEnabled = false
    let suite = "DockAutoHide.LoginMenuRegression.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let localization = AppLocalization(
      configStore: AppConfigurationStore(defaults: defaults), preferredLanguages: ["en"]
    )
    let dock = DockManager()
    let service = MenuLoginService()
    let login = LaunchAtLoginManager(service: service, localization: localization)
    let controller = MenuBarManager(
      dockManager: dock, launchAtLoginManager: login, statusItemFactory: { nil }, localization: localization
    )
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }
    // AppKit revalidates menu items immediately before keyboard/mouse dispatch.
    // The rendered disabled state must survive that validation pass.
    for authorized in [false, true] {
      for smart in [false, true] {
        dock.isAuthorized = authorized
        dock.smartEnabled = smart
        let candidate = controller.makeMenu()
        candidate.update()
        let smartItem = candidate.items.first { $0.action == NSSelectorFromString("toggleSmartEnabled") }!
        let manualItem = candidate.items.first { $0.action == NSSelectorFromString("toggleManualAutoHide") }!
        check(smartItem.isEnabled == authorized, "Smart control remains disabled without Automation permission after AppKit validation")
        check(manualItem.isEnabled == (authorized && !smart), "Manual control remains disabled during smart mode after AppKit validation")
      }
    }
    dock.isAuthorized = true
    dock.smartEnabled = false
    let menu = controller.makeMenu()
    for state in [LaunchAtLoginStatus.unavailable, .requiresApproval, .enabled, .notRegistered] {
      service.status = state
      controller.menuWillOpen(menu)
      menu.update()
      let item = menu.item(withTag: 1001)!
      check(item.isEnabled == (state != .unavailable), "Only unavailable bundles disable login registration")
      check(item.state == (state == .enabled ? .on : state == .requiresApproval ? .mixed : .off), "Actual menu checkmark must reflect four states")
      check(menu.item(withTag: 1002)!.isHidden == (state == .enabled || state == .notRegistered), "Pending/unavailable explanation must be visible")
      check(menu.item(withTag: 1004)!.isHidden == (state == .enabled || state == .notRegistered), "Settings link must appear for pending/unavailable states")
    }
    let quit = menu.items.first { $0.action == NSSelectorFromString("quitApp") }!
    check(quit.target === controller && quit.keyEquivalent == "q" && quit.keyEquivalentModifierMask == .command, "Quit maps to Command-Q and the production controller")
    check(menu.items.filter { !$0.keyEquivalent.isEmpty }.count == 1, "Menu-only configuration has no undocumented shortcut collisions")
    let probe = QuitProbe()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = probe
    func key(_ characters: String, modifiers: NSEvent.ModifierFlags, code: UInt16) -> Bool {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil, characters: modifiers.contains(.shift) ? characters.uppercased() : characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
      return menu.performKeyEquivalent(with: event)
    }
    check(!key("q", modifiers: [], code: 12), "Unmodified Q must not quit")
    check(!key(",", modifiers: .command, code: 43), "Command-comma has no app settings action in the status menu")
    check(!key("w", modifiers: .command, code: 13), "Command-W has no window action in the windowless status menu")
    check(!key("\u{1b}", modifiers: [], code: 53), "Escape does not dispatch a product action")
    check(key("q", modifiers: .command, code: 12) && probe.requests == 1, "Command-Q reaches production quit and requests application termination exactly once")
    NSApplication.shared.delegate = originalDelegate
    check(service.mutations == 0, "Menu refresh and validation must be read-only")
    dock.isAuthorized = false
    controller.menuWillOpen(menu)
    menu.update()
    check(menu.item(withTag: 1001)!.isEnabled, "Login registration is independent of Dock Automation permission")
    dock.isAuthorized = true
    login.setLaunchAtLogin(true)
    controller.menuWillOpen(menu)
    check(!menu.item(withTag: 1003)!.isHidden && menu.item(withTag: 1003)!.title.contains("Fixture login failure"), "Operation failures remain visible in the actual menu")
    localization.setLanguage(.simplifiedChinese)
    let translated = controller.makeMenu()
    check(translated.item(withTag: 1003)!.title == "登录项错误：Fixture login failure", "Existing system error is retained under a translated prefix")
    check(dock.policyMutations == 0 && dock.permissionRequests == 0, "Localization leaves Dock and permission boundaries untouched")
    let translatedQuit = translated.items.first { $0.action == NSSelectorFromString("quitApp") }!
    check(translatedQuit.keyEquivalent == "q" && translatedQuit.keyEquivalentModifierMask == .command && translatedQuit.target === controller, "Language changes preserve quit shortcut and action")
    let smartAction = translated.items.first { $0.action == NSSelectorFromString("toggleSmartEnabled") }!
    check(NSApplication.shared.sendAction(smartAction.action!, to: smartAction.target, from: smartAction), "Smart menu action dispatches")
    check(dock.smartEnabled && dock.policyMutations == 1, "Smart action enables the injected policy once")
    check(NSApplication.shared.sendAction(smartAction.action!, to: smartAction.target, from: smartAction), "Smart menu action dispatches again")
    check(!dock.smartEnabled && dock.policyMutations == 2, "Smart action disables the injected policy once")
    let manualAction = translated.items.first { $0.action == NSSelectorFromString("toggleManualAutoHide") }!
    check(NSApplication.shared.sendAction(manualAction.action!, to: manualAction.target, from: manualAction), "Manual menu action dispatches")
    check(dock.manualAutoHideEnabled && dock.policyMutations == 3, "Manual action toggles only the injected policy")
    check(dock.permissionRequests == 0, "Keyboard and menu checks never request real permissions")
    print("isolated AppKit login menu regressions passed (\(checks) checks); no real status item, Dock, or login mutation")
  }
}
