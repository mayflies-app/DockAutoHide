import AppKit
import Foundation

protocol DockAutomationControlling {
  func setAutoHide(_ enabled: Bool) -> Bool
  func readAutoHide() -> Bool?
}

/// Automation layer: controls Dock auto-hide via System Events.
final class DockAutomationService: DockAutomationControlling {
  func setAutoHide(_ enabled: Bool) -> Bool {
    let frontmost = NSWorkspace.shared.frontmostApplication
    let value = enabled ? "true" : "false"
    let script = """
      tell application "System Events"
          set autohide of dock preferences to \(value)
          return autohide of dock preferences
      end tell
      """
    let result = executeBoolScript(script)
    restoreFrontmost(frontmost)
    if let result {
      return result == enabled
    }
    return false
  }

  func readAutoHide() -> Bool? {
    let script = """
      tell application "System Events"
          return autohide of dock preferences
      end tell
      """
    return executeBoolScript(script)
  }

  private func executeBoolScript(_ source: String) -> Bool? {
    guard let appleScript = NSAppleScript(source: source) else {
      DockLogger.log("AppleScript init failed")
      return nil
    }
    var error: NSDictionary?
    let result = appleScript.executeAndReturnError(&error)
    if let error {
      let code = error[NSAppleScript.errorNumber] as? Int ?? 0
      let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
      DockLogger.log("AppleScript error: \(message) (code \(code))")
      return nil
    }
    return result.booleanValue
  }

  private func restoreFrontmost(_ app: NSRunningApplication?) {
    guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
      return
    }
    DispatchQueue.main.async {
      _ = app.activate(options: [.activateAllWindows])
    }
  }
}
