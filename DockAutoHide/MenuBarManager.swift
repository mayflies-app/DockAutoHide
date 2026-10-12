import Cocoa
import Combine
import SwiftUI

/// Menu bar controller for the status item and menu.
@MainActor
class MenuBarManager: NSObject, NSMenuDelegate, NSMenuItemValidation {
  private var statusItem: NSStatusItem?
  private let statusItemFactory: () -> NSStatusItem?
  private let dockManager: DockManager
  private let launchAtLoginManager: LaunchAtLoginManager
  private var cancellables = Set<AnyCancellable>()

  init(
    dockManager: DockManager, launchAtLoginManager: LaunchAtLoginManager,
    statusItemFactory: (() -> NSStatusItem?)? = nil
  ) {
    self.dockManager = dockManager
    self.launchAtLoginManager = launchAtLoginManager
    self.statusItemFactory = statusItemFactory ?? {
      NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }
    super.init()
    setupMenuBar()

    // Observe DockManager updates.
    dockManager.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        // Schedule on the next run loop so @Published values have updated.
        DispatchQueue.main.async {
          self?.updateMenu()
        }
      }
      .store(in: &cancellables)

    launchAtLoginManager.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.updateMenu() }
      }
      .store(in: &cancellables)
  }

  // Refresh visible login rows when a user opens the menu after a system change.
  func menuWillOpen(_ menu: NSMenu) {
    launchAtLoginManager.refreshStatus()
    configureLoginItems(in: menu)
  }

  /// Configures the status item and menu.
  private func setupMenuBar() {
    statusItem = statusItemFactory()

    if let button = statusItem?.button {
      button.image = NSImage(
        systemSymbolName: "dock.rectangle",
        accessibilityDescription: "DockAutoHide"
      )
      button.toolTip = "DockAutoHide"
    }

    updateMenu()
  }

  /// Builds the menu independently of attaching a real status item.
  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self

    let isAuthorized = dockManager.isAuthorized

    // Smart switching.
    let smartItem = NSMenuItem(
      title: "Smart Switching",
      action: #selector(toggleSmartEnabled),
      keyEquivalent: ""
    )
    smartItem.target = self
    smartItem.state = dockManager.smartEnabled ? .on : .off
    smartItem.isEnabled = isAuthorized
    menu.addItem(smartItem)

    // Manual Dock auto-hide.
    let manualItem = NSMenuItem(
      title: "Dock Auto-Hide",
      action: #selector(toggleManualAutoHide),
      keyEquivalent: ""
    )
    manualItem.target = self
    manualItem.state = dockManager.manualAutoHideEnabled ? .on : .off
    manualItem.isEnabled = isAuthorized && !dockManager.smartEnabled
    menu.addItem(manualItem)

    let statusTitle: String
    if isAuthorized {
      statusTitle =
        dockManager.currentAutoHideEnabled
        ? "Status: Auto-hide On" : "Status: Auto-hide Off"
    } else {
      statusTitle = "Status: Not Authorized"
    }
    let statusMenuItem = NSMenuItem(
      title: statusTitle,
      action: nil,
      keyEquivalent: ""
    )
    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)

    if let errorMessage = dockManager.lastErrorMessage {
      let errorItem = NSMenuItem(
        title: "Error: \(errorMessage)",
        action: nil,
        keyEquivalent: ""
      )
      errorItem.isEnabled = false
      menu.addItem(errorItem)
    }

    if !isAuthorized {
      let authItem = NSMenuItem(
        title: "Request System Events Permission",
        action: #selector(requestAuthorization),
        keyEquivalent: ""
      )
      authItem.target = self
      menu.addItem(authItem)
    }

    menu.addItem(NSMenuItem.separator())

    // Launch at login.
    let launchAtLoginItem = NSMenuItem(
      title: "Launch at Login",
      action: #selector(toggleLaunchAtLogin),
      keyEquivalent: ""
    )
    launchAtLoginItem.target = self
    launchAtLoginItem.tag = 1001
    menu.addItem(launchAtLoginItem)
    let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    detailItem.tag = 1002
    detailItem.isEnabled = false
    menu.addItem(detailItem)
    let loginErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    loginErrorItem.tag = 1003
    loginErrorItem.isEnabled = false
    menu.addItem(loginErrorItem)
    let settingsItem = NSMenuItem(
      title: "Open Login Items Settings…", action: #selector(openLoginItemsSettings), keyEquivalent: ""
    )
    settingsItem.tag = 1004
    settingsItem.target = self
    menu.addItem(settingsItem)
    configureLoginItems(in: menu)

    menu.addItem(NSMenuItem.separator())

    let versionItem = NSMenuItem(
      title: versionMenuTitle(),
      action: nil,
      keyEquivalent: ""
    )
    versionItem.isEnabled = false
    menu.addItem(versionItem)

    // Quit.
    let quitItem = NSMenuItem(
      title: "Quit",
      action: #selector(quitApp),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    return menu
  }

  private func updateMenu() {
    let menu = makeMenu()
    // Setting the status item's menu while the menu/button is being laid out
    // or while the menu is open can trigger AppKit layout recursion. If the
    // button is highlighted (menu open), defer the replacement to the next
    // run loop iteration to avoid calling into layout while AppKit is busy.
    if let button = statusItem?.button, button.isHighlighted {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.statusItem?.menu = menu
      }
    } else {
      statusItem?.menu = menu
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.tag == 1001 {
      return launchAtLoginManager.canToggle
    }
    // Preserve AppKit's existing automatic enabling for the other actions.
    return true
  }

  private func configureLoginItems(in menu: NSMenu) {
    let manager = launchAtLoginManager
    if let item = menu.item(withTag: 1001) {
      switch manager.status {
      case .enabled: item.state = .on
      case .requiresApproval: item.state = .mixed
      case .notRegistered, .unavailable: item.state = .off
      }
      item.isEnabled = manager.canToggle
    }
    if let item = menu.item(withTag: 1002) {
      item.title = manager.statusDetail ?? ""
      item.isHidden = manager.statusDetail == nil
    }
    if let item = menu.item(withTag: 1003) {
      item.title = manager.lastErrorMessage.map { "Login Item Error: \($0)" } ?? ""
      item.isHidden = manager.lastErrorMessage == nil
    }
    menu.item(withTag: 1004)?.isHidden = manager.status != .requiresApproval && manager.status != .unavailable
  }

  @objc private func openLoginItemsSettings() {
    launchAtLoginManager.openSettings()
  }

  /// Toggles smart switching.
  @objc private func toggleSmartEnabled() {
    let newState = !dockManager.smartEnabled
    dockManager.setSmartEnabled(newState)
    DockLogger
      .log("User toggled smart switching: \(newState ? "enabled" : "disabled")")
  }

  @objc private func toggleManualAutoHide() {
    let newState = !dockManager.manualAutoHideEnabled
    dockManager.setManualAutoHideEnabled(newState)
    DockLogger
      .log("User toggled Dock auto-hide: \(newState ? "enabled" : "disabled")")
  }

  @objc private func requestAuthorization() {
    dockManager.requestAuthorizationFromUser()
    DockLogger.log("User requested System Events permission")
  }

  /// Toggles launch at login.
  @objc private func toggleLaunchAtLogin() {
    launchAtLoginManager.toggle()
    updateMenu()
  }

  /// Quits the app.
  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  private func versionMenuTitle() -> String {
    let shortVersion =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "0.0.0"
    let buildNumber =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String ?? "0"
    return "Version: v\(shortVersion) (\(buildNumber))"
  }

  /// Releases the status item.
  deinit {
    statusItem = nil
  }
}
