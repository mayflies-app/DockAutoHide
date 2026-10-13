import AppKit
import Combine
import Foundation

// The real coordinator and menu run against these system boundaries only.
enum DockAuthorizationState: String { case authorized, denied, notDetermined }
final class DockAuthorizationManager: ObservableObject {
  @Published var state: DockAuthorizationState = .denied
  var launchRequests = 0
  var userRequests = 0
  func requestAccessOnLaunch() { launchRequests += 1 }
  func requestAccessFromUser() { userRequests += 1 }
}
enum ScreenCapturePermission { static var hasAccess: Bool { true } }
protocol DockAutomationControlling {
  func setAutoHide(_ enabled: Bool) -> Bool
  func readAutoHide() -> Bool?
}
final class DockAutomationService: DockAutomationControlling {
  var reads = 0
  var writes = 0
  var succeeds = false
  func setAutoHide(_ enabled: Bool) -> Bool { writes += 1; return succeeds }
  func readAutoHide() -> Bool? { reads += 1; return false }
}
@MainActor private final class LocalizationLoginService: LaunchAtLoginService {
  var status: LaunchAtLoginStatus = .requiresApproval
  var reads = 0
  var mutations = 0
  func readStatus() -> LaunchAtLoginStatus { reads += 1; return status }
  func register() throws { mutations += 1 }
  func unregister() throws { mutations += 1 }
  func openSettings() { mutations += 1 }
}

@main private enum LocalizationRegression {
  @MainActor static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    DockLogger.isEnabled = false
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }
    func settle(_ duration: TimeInterval = 0.03) async {
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
    func waitUntil(_ description: String, _ condition: () -> Bool) async {
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      precondition(condition(), "Timed out waiting for \(description)")
    }
    check(Bundle.main.bundleURL.pathExtension == "app", "The fixture loads the same app-bundle resource layout as Xcode")
    let expectedKeys = Set(AppText.allCases.map(\.rawValue))
    let english = LocalizationResources.catalog(language: "en", bundle: .main)
    let chinese = LocalizationResources.catalog(language: "zh-Hans", bundle: .main)
    check(Set(english.keys) == expectedKeys, "English resources cover exactly the app's semantic keys")
    check(Set(chinese.keys) == expectedKeys, "Chinese resources cover exactly the app's semantic keys")
    check(english.values.allSatisfy { !$0.isEmpty } && chinese.values.allSatisfy { !$0.isEmpty }, "Both resource tables contain translations")
    check(LocalizationResources.catalog(language: "ZH-hans", bundle: .main) == chinese, "Resource lookup tolerates localization-directory case")
    for language in ["en", "zh-Hans"] {
      let info = LocalizationResources.catalog(language: language, table: "InfoPlist", bundle: .main)
      check(Set(info.keys) == Set(["CFBundleName", "CFBundleDisplayName", "NSAppleEventsUsageDescription"]), "Localized app metadata and Automation descriptions are bundled")
      check(info.values.allSatisfy { !$0.isEmpty }, "Localized app metadata has no empty values")
    }
    let sparseURL = FileManager.default.temporaryDirectory.appendingPathComponent("DockLocalizationFallback-\(UUID().uuidString).bundle")
    defer { try? FileManager.default.removeItem(at: sparseURL) }
    for language in ["en", "zh-Hans"] {
      try! FileManager.default.createDirectory(at: sparseURL.appendingPathComponent("\(language).lproj"), withIntermediateDirectories: true)
    }
    try! "\"fixture.fallback\" = \"English fallback\";\n".write(to: sparseURL.appendingPathComponent("en.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
    try! "\"fixture.chinese\" = \"中文\";\n".write(to: sparseURL.appendingPathComponent("zh-Hans.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
    let sparse = Bundle(url: sparseURL)!
    check(LocalizationResources.string("fixture.fallback", language: "zh-Hans", bundle: sparse) == "English fallback", "A missing selected-language key falls back to English")
    check(LocalizationResources.string("fixture.missing", language: "zh-Hans", bundle: sparse) == "fixture.missing", "A key absent from both tables remains diagnosable")
    let suite = "DockAutoHide.LocalizationRegression.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppConfigurationStore(defaults: defaults)
    check(AppLanguage.preferred(from: ["de-DE", "zh-Hans-CN", "en-US"]) == .simplifiedChinese, "First supported system preference wins")
    check(AppLanguage.preferred(from: ["fr", "en-GB", "zh-Hans"]) == .english, "English before Chinese wins")
    check(AppLanguage.preferred(from: ["zh_TW", "en"]) == .simplifiedChinese, "Chinese locales select simplified app UI")
    check(AppLanguage.preferred(from: ["ja-JP"]) == .english, "Unsupported system preferences fall back to English")
    check(AppLanguage.preferred(from: []) == .english, "Empty preference list falls back to English")
    let localization = AppLocalization(configStore: store, preferredLanguages: ["en-US", "zh-Hans"])
    check(localization.language == .english, "Fresh app chooses the first supported system language")
    check(store.readLanguage() == nil, "Reading defaults does not persist a language or mutate Dock policy")
    defaults.set("invalid", forKey: "DockAutoHide.language")
    check(AppLocalization(configStore: store, preferredLanguages: ["zh-Hans"]).language == .simplifiedChinese, "Invalid preference falls back to system selection")
    defaults.removeObject(forKey: "DockAutoHide.language")
    for key in AppText.allCases {
      check(!key.value(in: .english).isEmpty && !key.value(in: .simplifiedChinese).isEmpty, "Every visible text has both languages")
      check(key.value(in: .english) != key.value(in: .simplifiedChinese), "Every app string translates")
    }
    let auth = DockAuthorizationManager()
    let automation = DockAutomationService()
    let dock = DockManager(automationService: automation, authorizationManager: auth, configStore: store, localization: localization)
    let loginService = LocalizationLoginService()
    let login = LaunchAtLoginManager(service: loginService, localization: localization)
    let controller = MenuBarManager(dockManager: dock, launchAtLoginManager: login, statusItemFactory: { nil }, localization: localization)
    await settle()
    dock.setSmartEnabled(true)
    check(dock.lastErrorMessage == "System Events permission is required to use this feature.", "Real coordinator generates feature permission error")
    let beforeSmart = dock.smartEnabled
    let beforeManual = dock.manualAutoHideEnabled
    let beforeCurrent = dock.currentAutoHideEnabled
    let beforeDefaults = defaults.persistentDomain(forName: suite) ?? [:]
    let beforeAuth = auth.launchRequests + auth.userRequests
    let beforeLoginReads = loginService.reads
    let englishMenu = controller.makeMenu()
    check(englishMenu.items.contains { $0.title == "Error: System Events permission is required to use this feature." }, "Existing English error is visible")
    let submenu = englishMenu.item(withTag: 2000)!.submenu!
    check(submenu.items.map(\.title) == ["简体中文", "English"], "Language choices use their own names")
    let chineseItem = submenu.items.first { $0.title == "简体中文" }!
    check(NSApplication.shared.sendAction(chineseItem.action!, to: chineseItem.target, from: chineseItem), "Native language menu action dispatches")
    await settle()
    check(localization.language == .simplifiedChinese && store.readLanguage() == .simplifiedChinese, "Language menu persists its selection")
    check(AppLocalization(configStore: store, preferredLanguages: ["en"]).language == .simplifiedChinese, "Saved language wins after relaunch")
    check(dock.lastErrorMessage == "使用此功能需要“系统事件”权限。", "Existing real coordinator error updates after language switch")
    check(login.statusDetail == "登录时启动需要在系统设置中批准。", "Existing login approval explanation updates")
    let chineseMenu = controller.makeMenu()
    let titles = chineseMenu.items.map(\.title)
    for title in ["智能切换", "自动隐藏 Dock", "状态：需要“系统事件”权限", "错误：使用此功能需要“系统事件”权限。", "请求“系统事件”权限", "登录时启动", "打开登录项设置…", "界面语言", "退出"] {
      check(titles.contains(title), "Chinese menu covers \(title)")
    }
    check(titles.contains { $0.hasPrefix("版本：v") }, "Version prefix updates")
    check(chineseMenu.item(withTag: 2000)!.submenu!.items.first!.state == .on, "Selected language checkmark updates")
    check(dock.smartEnabled == beforeSmart && dock.manualAutoHideEnabled == beforeManual && dock.currentAutoHideEnabled == beforeCurrent, "Language action does not change any Dock policy or state")
    check(automation.reads == 0 && automation.writes == 0 && auth.launchRequests + auth.userRequests == beforeAuth, "Language action makes no Dock automation or permission calls")
    check(loginService.mutations == 0 && loginService.reads == beforeLoginReads, "Language action makes no login service calls")
    var afterDefaults = defaults.persistentDomain(forName: suite) ?? [:]
    afterDefaults.removeValue(forKey: "DockAutoHide.language")
    check(NSDictionary(dictionary: afterDefaults).isEqual(to: beforeDefaults), "Language action persists only language")
    loginService.status = .unavailable
    login.refreshStatus()
    check(login.statusDetail == "此应用暂时无法使用登录时启动。", "Unavailable login explanation translates")
    // Trigger each coordinator error through real behavior using fake services.
    auth.state = .notDetermined
    await settle()
    check(dock.lastErrorMessage == "控制 Dock 需要“系统事件”权限。", "Authorization error uses active language")
    localization.setLanguage(.english)
    check(dock.lastErrorMessage == "System Events permission is required to control the Dock.", "Existing authorization error translates back")
    store.writeManualAutoHideEnabled(true)
    auth.state = .authorized
    await settle(0.4)
    check(automation.writes == 1 && dock.lastErrorMessage == "Failed to apply Dock auto-hide via System Events.", "Failed apply reports a generated error")
    localization.setLanguage(.simplifiedChinese)
    check(dock.lastErrorMessage == "通过“系统事件”设置 Dock 自动隐藏失败。", "Existing apply failure translates")
    dock.restoreManualAutoHideOnQuit()
    check(dock.lastErrorMessage == "退出前恢复 Dock 自动隐藏失败。", "Quit restore failure uses active language")
    localization.setLanguage(.english)
    check(dock.lastErrorMessage == "Failed to restore Dock auto-hide before quitting.", "Existing restore failure translates back")
    check(controller.makeMenu().items.contains { $0.title == "Status: Auto-Hide Off" }, "Authorized off status renders in English")
    automation.succeeds = true
    dock.setManualAutoHideEnabled(true)
    await settle(0.4)
    check(controller.makeMenu().items.contains { $0.title == "Status: Auto-Hide On" }, "Authorized on status renders in English")
    let authorizedReads = automation.reads
    let authorizedWrites = automation.writes
    let authorizedRequests = auth.launchRequests + auth.userRequests
    // Native status button is an isolated fixture, never the production app.
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    defer { NSStatusBar.system.removeStatusItem(status) }
    let nativeController = MenuBarManager(dockManager: dock, launchAtLoginManager: login, statusItemFactory: { status }, localization: localization)
    check(status.button?.toolTip == "Dock Auto Hide" && status.button?.accessibilityLabel() == "Dock Auto Hide", "English native tooltip and accessibility label")
    localization.setLanguage(.simplifiedChinese)
    await settle()
    check(status.button?.toolTip == "Dock 自动隐藏" && status.button?.accessibilityLabel() == "Dock 自动隐藏", "Existing native tooltip and accessibility label update")
    check(status.button?.image?.accessibilityDescription == "Dock 自动隐藏", "Existing status image accessibility text updates")
    check(status.menu?.items.contains { $0.title == "界面语言" } == true, "Existing native menu updates")
    check(status.menu?.items.contains { $0.title == "状态：自动隐藏已开启" } == true, "Authorized on status renders in Chinese")
    let englishItem = status.menu!.item(withTag: 2000)!.submenu!.items.first { $0.title == "English" }!
    check(NSApplication.shared.sendAction(englishItem.action!, to: englishItem.target, from: englishItem), "Native language menu switches back to English")
    check(status.button?.toolTip == "Dock Auto Hide", "Menu action updates native tooltip immediately")
    check(automation.reads == authorizedReads && automation.writes == authorizedWrites && auth.launchRequests + auth.userRequests == authorizedRequests, "Authorized language action makes no Dock or permission calls")
    localization.setLanguage(.simplifiedChinese)
    dock.setManualAutoHideEnabled(false)
    await waitUntil("the attached menu to show Chinese auto-hide off status") {
      status.menu?.items.contains { $0.title == "状态：自动隐藏已关闭" } == true
    }
    check(status.menu?.items.contains { $0.title == "状态：自动隐藏已关闭" } == true, "Authorized off status renders in Chinese")
    withExtendedLifetime(nativeController) {}
    print("isolated localization regressions passed (\(checks) checks); production app not launched; real Dock writes, Automation requests and login mutations: 0")
  }
}
