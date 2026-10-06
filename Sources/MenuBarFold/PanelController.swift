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

        // Anchor below the chevron. On macOS 27 the status item's button
        // lives in a full-width host window, so use the chevron's AX
        // position (top-left screen coords) instead of the window frame.
        guard let screen = NSScreen.main else { return }
        let menuBarHeight: CGFloat = 33
        let panelTopY = screen.frame.maxY - menuBarHeight - 4 // AppKit: bottom-left origin
        if let ax = appState.controlItems.anchorX() {
            let centerX = ax + 11 // chevron is ~22pt wide
            let x = min(max(4, centerX - width / 2), screen.frame.maxX - width - 4)
            panel.setFrameOrigin(NSPoint(x: x, y: panelTopY - height))
        } else {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.maxX - width - 8,
                y: panelTopY - height
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
