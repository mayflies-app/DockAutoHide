import SwiftUI

@main
struct DockAutoHideApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    // Keep the app windowless; configuration lives in the status menu.
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {}
    }
  }
}

// App Delegate manages the menu bar app.
class AppDelegate: NSObject, NSApplicationDelegate {
  private var menuBarManager: MenuBarManager?
  private var dockManager = DockManager()
  private var launchAtLoginManager = LaunchAtLoginManager()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Hide Dock icon.
    NSApp.setActivationPolicy(.accessory)

    // Create the menu bar manager.
    menuBarManager = MenuBarManager(
      dockManager: dockManager,
      launchAtLoginManager: launchAtLoginManager
    )
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication)
    -> Bool
  {
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
    dockManager.restoreManualAutoHideOnQuit()
    return .terminateNow
  }
}
