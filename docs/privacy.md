# Privacy

## Local Data

Dock Auto Hide reads display and window geometry and Dock preferences to determine overlap. It does not record screenshots or window contents. Language, Smart Switching and manual auto-hide preferences are stored in macOS user defaults under `app.mayfiles.DockAutoHide`.

The app restores the chosen manual auto-hide setting when quitting with Automation permission. Disable Launch at Login and quit before uninstalling. The app bundle, saved preferences and macOS permission grants are managed separately; choose another Dock setting in System Settings if needed after removal.

## Network Access

All processing stays on the Mac. The app makes no network requests and has no analytics, telemetry or project-operated server.

## Permissions

System Events Automation permission is required to read and change Dock auto-hide through Apple Events. Grant it in **System Settings → Privacy & Security → Automation**.

Optional Screen Recording permission provides fuller window metadata. The app does not proactively request it or capture the screen. Without it, Smart Switching uses available metadata and fallback geometry; complex multi-display arrangements can be less precise. Manual control remains available with Automation permission.

Launch at Login uses macOS Login Items and can require approval in System Settings. System permission dialogs use the macOS language independently of the app language.
