import Combine
import Foundation

/// Configuration layer for persisted settings.
final class AppConfigurationStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private enum Keys {
    static let language = "DockAutoHide.language"
    static let smartEnabled = "DockAutoHide.smartEnabled"
    static let manualAutoHideEnabled = "DockAutoHide.manualAutoHideEnabled"
  }

  func readLanguage() -> AppLanguage? {
    defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:))
  }

  func writeLanguage(_ value: AppLanguage) {
    defaults.set(value.rawValue, forKey: Keys.language)
  }

  func readSmartEnabled() -> Bool? {
    return defaults.object(forKey: Keys.smartEnabled) as? Bool
  }

  func writeSmartEnabled(_ value: Bool) {
    defaults.set(value, forKey: Keys.smartEnabled)
  }

  func readManualAutoHideEnabled() -> Bool? {
    return defaults.object(forKey: Keys.manualAutoHideEnabled) as? Bool
  }

  func writeManualAutoHideEnabled(_ value: Bool) {
    defaults.set(value, forKey: Keys.manualAutoHideEnabled)
  }
}

/// The app's language is independent of macOS permission-dialog language.
enum AppLanguage: String, CaseIterable {
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  var displayName: String {
    switch self {
    case .simplifiedChinese: return "简体中文"
    case .english: return "English"
    }
  }

  static func preferred(from languages: [String]) -> AppLanguage {
    for identifier in languages {
      let base = identifier.replacingOccurrences(of: "_", with: "-")
        .split(separator: "-").first?.lowercased()
      if base == "zh" { return .simplifiedChinese }
      if base == "en" { return .english }
    }
    return .english
  }
}

enum AppText: String, CaseIterable {
  case appName = "app.name"
  case smartSwitching = "menu.smartSwitching"
  case dockAutoHide = "menu.dockAutoHide"
  case statusOn = "status.autoHideOn"
  case statusOff = "status.autoHideOff"
  case notAuthorized = "status.permissionRequired"
  case errorPrefix = "error.prefix"
  case requestPermission = "menu.requestPermission"
  case launchAtLogin = "menu.launchAtLogin"
  case loginSettings = "menu.loginSettings"
  case loginErrorPrefix = "error.loginPrefix"
  case language = "menu.language"
  case version = "app.version"
  case quit = "menu.quit"
  case loginApproval = "login.approvalRequired"
  case loginUnavailable = "login.unavailable"
  case featurePermissionRequired = "error.featurePermissionRequired"
  case dockPermissionRequired = "error.dockPermissionRequired"
  case restoreFailed = "error.restoreFailed"
  case applyFailed = "error.applyFailed"

  func value(in language: AppLanguage) -> String {
    LocalizationResources.string(rawValue, language: language.rawValue, bundle: .main)
  }
}

/// A language change persists only this preference; consumers refresh presentation.
final class AppLocalization: ObservableObject {
  static let shared = AppLocalization()
  @Published private(set) var language: AppLanguage
  private let configStore: AppConfigurationStore

  init(
    configStore: AppConfigurationStore = AppConfigurationStore(),
    preferredLanguages: [String] = Locale.preferredLanguages
  ) {
    self.configStore = configStore
    self.language = configStore.readLanguage() ?? AppLanguage.preferred(from: preferredLanguages)
  }

  func setLanguage(_ language: AppLanguage) {
    guard language != self.language else { return }
    configStore.writeLanguage(language)
    self.language = language
  }

  func text(_ key: AppText) -> String { key.value(in: language) }
}
