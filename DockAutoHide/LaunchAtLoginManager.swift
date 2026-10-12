import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
  case notRegistered
  case enabled
  case requiresApproval
  case unavailable

  init(serviceStatus: SMAppService.Status, hasApplicationBundle: Bool) {
    guard hasApplicationBundle else { self = .unavailable; return }
    switch serviceStatus {
    case .enabled: self = .enabled
    case .notRegistered, .notFound:
      // A main app can have no BTM record before its first registration.
      self = .notRegistered
    case .requiresApproval: self = .requiresApproval
    @unknown default: self = .unavailable
    }
  }
}

@MainActor
protocol LaunchAtLoginService {
  func readStatus() -> LaunchAtLoginStatus
  func register() throws
  func unregister() throws
  func openSettings()
}

@MainActor
private struct SystemLaunchAtLoginService: LaunchAtLoginService {
  func readStatus() -> LaunchAtLoginStatus {
    LaunchAtLoginStatus(
      serviceStatus: SMAppService.mainApp.status,
      hasApplicationBundle: Bundle.main.bundleURL.pathExtension == "app"
        && Bundle.main.bundleIdentifier != nil
    )
  }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Reads the real service state; only explicit user actions change login items.
@MainActor
class LaunchAtLoginManager: ObservableObject {
  @Published private(set) var status: LaunchAtLoginStatus = .notRegistered
  @Published private(set) var lastErrorMessage: String?
  private let localization: AppLocalization
  private let service: any LaunchAtLoginService

  var isEnabled: Bool { status == .enabled }
  var canToggle: Bool { status != .unavailable }
  var statusDetail: String? {
    switch status {
    case .requiresApproval: return localization.text(.loginApproval)
    case .unavailable: return localization.text(.loginUnavailable)
    case .enabled, .notRegistered: return nil
    }
  }

  init(
    service: (any LaunchAtLoginService)? = nil, localization: AppLocalization? = nil
  ) {
    self.localization = localization ?? .shared
    self.service = service ?? SystemLaunchAtLoginService()
    refreshStatus()
  }

  func refreshStatus() {
    let actual = service.readStatus()
    // A menu refresh must not republish an unchanged value and trigger a loop.
    if actual != status { status = actual }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    refreshStatus()
    guard status != .unavailable else { return }
    if enabled && status == .requiresApproval {
      openSettings()
      return
    }
    guard enabled != isEnabled || status == .requiresApproval else { return }
    if lastErrorMessage != nil { lastErrorMessage = nil }
    defer { refreshStatus() }
    do {
      if enabled { try service.register() }
      else { try service.unregister() }
    } catch {
      lastErrorMessage = error.localizedDescription
      DockLogger.log("Failed to set launch at login: \(error)")
    }
  }

  func toggle() {
    refreshStatus()
    if status == .requiresApproval { openSettings() }
    else { setLaunchAtLogin(!isEnabled) }
  }

  func openSettings() { service.openSettings() }
}
