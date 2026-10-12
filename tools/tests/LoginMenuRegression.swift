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
  func setSmartEnabled(_ enabled: Bool) { policyMutations += 1 }
  func setManualAutoHideEnabled(_ enabled: Bool) { policyMutations += 1 }
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
    print("isolated AppKit login menu regressions passed (\(checks) checks); no real status item, Dock, or login mutation")
  }
}
