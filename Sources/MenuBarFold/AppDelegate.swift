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

        appState.controlItems.setup()
        appState.controlItems.onChevronClick = { [weak appState] in
            appState?.panelController.toggle()
        }
        appState.itemManager.performSetup(appState: appState)

        ensureAccessibilityPermission()

        // Global hotkey ⌃⌥M toggles the panel — needed because on macOS 27
        // the system may park our status item where it can't be clicked.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak appState] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.control, .option], event.keyCode == 46 {
                Task { @MainActor in appState?.panelController.toggle() }
            }
        }

        log("didFinishLaunching")

        Task { @MainActor in
            await appState.itemManager.controlItemsDidAppear()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.controlItems.teardown()
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
