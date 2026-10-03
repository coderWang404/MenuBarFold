import Cocoa
import SwiftUI

/// The dropdown panel anchored below our chevron status item.
@MainActor
final class PanelController: NSObject {
    private weak var appState: AppState?
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var observer: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard let appState else { return }
        appState.itemManager.refresh()

        let width: CGFloat = 300
        let view = PanelView(manager: appState.itemManager, controller: self)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false

        // Size to content.
        let fitting = hosting.fittingSize
        let height = min(max(fitting.height, 80), 480)
        panel.setContentSize(NSSize(width: width, height: height))

        // Anchor below the chevron button.
        if let buttonWindow = appState.controlItems.chevronItem?.button?.window {
            let bf = buttonWindow.frame // AppKit coords (bottom-left origin)
            let x = max(4, bf.midX - width / 2)
            panel.setFrameOrigin(NSPoint(x: x, y: bf.minY - height - 4))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.maxX - width - 8,
                y: screen.frame.maxY - height - 8
            ))
        }

        panel.orderFront(nil)
        self.panel = panel

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        panel?.close()
        panel = nil
    }
}
