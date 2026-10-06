import Cocoa

/// The app's own menu bar status item (the chevron toggle).
///
/// On macOS 27 the system itself owns item collapse; the app no longer
/// maintains a divider status item. The chevron is recreated if the system
/// parks it at an unreachable sentinel position.
@MainActor
final class ControlItems {
    private(set) var chevronItem: NSStatusItem?
    var chevronAXPosition: CGPoint?
    private var loggedParked = false

    var onChevronClick: (() -> Void)? {
        didSet { bindAction() }
    }

    func setup() {
        if chevronItem == nil { makeChevron() }
    }

    func teardown() {
        if let c = chevronItem { NSStatusBar.system.removeStatusItem(c) }
        chevronItem = nil
        chevronAXPosition = nil
    }

    /// Called with the AX positions of our own extras. On macOS 27 the
    /// system parks freshly created status items at a sentinel position —
    /// recreating does not bring them back, so we only record the position
    /// (the panel stays reachable via the global hotkey / the system ⌄ tray).
    func observeOwnExtras(positions: [CGPoint]) {
        let active = positions.first { $0.x >= 0 && $0.y >= 0 && $0.y < 40 }
        if active == nil && !loggedParked {
            loggedParked = true
            log("chevron parked at sentinel — panel is reachable via ⌃⌥M")
        }
        chevronAXPosition = active
    }

    /// Screen x-coordinate used to align the panel under the chevron.
    /// nil when the chevron has no usable bar position (parked sentinel
    /// coordinates like (7, 986) must never anchor the panel).
    func anchorX() -> CGFloat? {
        if let p = chevronAXPosition, p.x >= 0, p.y >= 0, p.y < 40 { return p.x }
        return nil
    }

    private func makeChevron() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "MenuBarFold.chevron"
        item.behavior = [.removalAllowed, .terminationOnRemoval]
        item.isVisible = true
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: "MenuBarFold"
            )
            button.imagePosition = .imageOnly
            button.sendAction(on: [.leftMouseUp])
        }
        chevronItem = item
        bindAction()
    }

    private func bindAction() {
        guard let button = chevronItem?.button else { return }
        button.target = self
        button.action = #selector(chevronClicked)
    }

    @objc private func chevronClicked() { onChevronClick?() }
}
