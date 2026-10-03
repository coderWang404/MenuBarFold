import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let appState = AppState()
        self.appState = appState

        appState.controlItems.setup { [weak appState] in
            appState?.panelController.toggle()
        }
        appState.itemManager.performSetup(appState: appState)

        ensureAccessibilityPermission()

        log("didFinishLaunching")

        Task { @MainActor in
            await appState.itemManager.controlItemsDidAppear()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.controlItems.setDividerExpanded(false)
    }

    /// Prompts for Accessibility permission if needed; menu bar item moves
    /// silently fail without it.
    private func ensureAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                Task { @MainActor in
                    self?.permissionTimer = nil
                }
            }
        }
    }
}
