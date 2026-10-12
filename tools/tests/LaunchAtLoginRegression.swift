import Foundation
import Combine
import ServiceManagement

@MainActor
private final class FakeLoginService: LaunchAtLoginService {
  var status: LaunchAtLoginStatus = .notRegistered
  var reads = 0
  var registers = 0
  var unregisters = 0
  var settings = 0
  var nextStatus: LaunchAtLoginStatus?
  var fails = false

  func readStatus() -> LaunchAtLoginStatus { reads += 1; return status }
  func register() throws {
    registers += 1
    if let nextStatus { status = nextStatus }
    if fails { throw NSError(domain: "LoginFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture registration failure"]) }
  }
  func unregister() throws {
    unregisters += 1
    if let nextStatus { status = nextStatus }
    if fails { throw NSError(domain: "LoginFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture unregister failure"]) }
  }
  func openSettings() { settings += 1 }
}

@main
private enum LoginRegression {
  @MainActor static func main() {
    DockLogger.isEnabled = false
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }
    for state in [LaunchAtLoginStatus.notRegistered, .enabled, .requiresApproval, .unavailable] {
      let service = FakeLoginService()
      service.status = state
      let manager = LaunchAtLoginManager(service: service)
      check(manager.status == state, "Initial status must reflect the actual service")
      check(manager.isEnabled == (state == .enabled), "Enabled must derive from actual state")
      check(service.registers == 0 && service.unregisters == 0 && service.settings == 0, "Status reads must not mutate service")
    }
    let service = FakeLoginService()
    let manager = LaunchAtLoginManager(service: service)
    service.nextStatus = .requiresApproval
    manager.setLaunchAtLogin(true)
    check(manager.status == .requiresApproval && !manager.isEnabled, "Pending approval must not show enabled")
    check(service.registers == 1, "Enable submits one registration")
    manager.toggle()
    check(service.registers == 1 && service.settings == 1, "Pending action opens settings without repeating registration")
    check(manager.statusDetail?.contains("approval") == true, "Pending state has explanatory text")
    service.status = .enabled
    manager.refreshStatus()
    check(manager.isEnabled, "Menu refresh observes an externally approved item")
    service.fails = true
    service.nextStatus = .enabled
    manager.setLaunchAtLogin(false)
    check(manager.isEnabled, "Failed disable preserves actual enabled state")
    check(manager.lastErrorMessage?.contains("Fixture unregister failure") == true, "Failed operation remains visible")
    manager.refreshStatus()
    check(manager.lastErrorMessage != nil, "Read refresh does not erase the failure")
    service.status = .notRegistered
    service.nextStatus = .notRegistered
    manager.setLaunchAtLogin(true)
    check(!manager.isEnabled && manager.lastErrorMessage != nil, "Failed registration does not optimistically enable")
    service.fails = false
    service.nextStatus = .enabled
    manager.setLaunchAtLogin(true)
    check(manager.isEnabled && manager.lastErrorMessage == nil, "Successful retry refreshes actual state and clears old failure")
    service.status = LaunchAtLoginStatus(serviceStatus: .notFound, hasApplicationBundle: true)
    service.nextStatus = .enabled
    let beforeFirstRegistration = service.registers
    manager.setLaunchAtLogin(true)
    check(service.registers == beforeFirstRegistration + 1, "First registration must reach the service when no BTM record exists")
    check(manager.isEnabled, "First registration refreshes the actual system status")
    check(LaunchAtLoginStatus(serviceStatus: .notFound, hasApplicationBundle: true) == .notRegistered,
          "Missing BTM record maps to unregistered, not unavailable")
    check(LaunchAtLoginStatus(serviceStatus: .enabled, hasApplicationBundle: false) == .unavailable,
          "Unbundled executables cannot offer main-app login registration")
    service.status = .unavailable
    let mutations = service.registers + service.unregisters
    manager.toggle()
    check(!manager.canToggle && service.registers + service.unregisters == mutations,
          "Unavailable bundles do not attempt login registration")
    check(manager.statusDetail?.contains("unavailable") == true, "Unavailable bundles explain why registration is disabled")
    var notifications = 0
    let observer = manager.objectWillChange.sink { _ in notifications += 1 }
    manager.refreshStatus()
    manager.refreshStatus()
    check(notifications == 0, "Unchanged status reads do not cause menu rebuild loops")
    withExtendedLifetime(observer) {}
    print("launch-at-login fake-service regressions passed (\(checks) checks); real login items unchanged")
  }
}
