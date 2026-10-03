import Cocoa

/// Our own status items: the chevron that toggles the panel, and the divider
/// that marks the fold boundary. Expanding the divider to a huge width pushes
/// everything ordered left of it off the screen (the Hidden Bar / Ice trick).
@MainActor
final class ControlItems {
    /// Chevron shown in the menu bar; clicking it toggles the panel.
    private(set) var chevronItem: NSStatusItem!

    /// Boundary item. Items ordered left of it are the folded set.
    private(set) var dividerItem: NSStatusItem!

    /// Window-server window IDs of our own items, resolved by window title
    /// (items are hosted by ControlCenter, so `button.window` is nil).
    var dividerWindowID: CGWindowID?
    var chevronWindowID: CGWindowID?

    /// Window-server IDs that belong to us — excluded from managed lists.
    var ownWindowIDs: Set<CGWindowID> {
        var set = Set<CGWindowID>()
        if let dividerWindowID { set.insert(dividerWindowID) }
        if let chevronWindowID { set.insert(chevronWindowID) }
        return set
    }

    /// Window-title prefix of our status items (autosaveName becomes the title).
    static let ownTitlePrefix = "MenuBarFold."

    /// Width used when the divider is expanded — enough to push everything
    /// left of it off screen but not absurdly far.
    private var expandedLength: CGFloat {
        let w = NSScreen.screens.map(\.frame.width).max() ?? 1512
        return w
    }

    func setup(onChevronClick: @escaping () -> Void) {
        dividerItem = NSStatusBar.system.statusItem(withLength: 6)
        dividerItem.autosaveName = "MenuBarFold.divider"
        dividerItem.button?.image = nil
        dividerItem.button?.isEnabled = false

        chevronItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        chevronItem.autosaveName = "MenuBarFold.chevron"
        if let button = chevronItem.button {
            let image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: "MenuBarFold")
                ?? NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "MenuBarFold")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(chevronClicked)
        }
        self.onChevronClick = onChevronClick
    }

    private var onChevronClick: (() -> Void)?

    @objc private func chevronClicked() {
        onChevronClick?()
    }

    var isDividerExpanded = false

    /// Expand (hide folded items) or collapse (reveal) the divider.
    func setDividerExpanded(_ expanded: Bool) {
        guard let dividerItem else { return }
        dividerItem.length = expanded ? expandedLength : 6
        isDividerExpanded = expanded
        log("divider length set to \(dividerItem.length)")
    }
}
