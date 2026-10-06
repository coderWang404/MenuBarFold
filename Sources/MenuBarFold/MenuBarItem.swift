import Cocoa
import ApplicationServices

/// A menu bar extra as seen through its owning app's AXExtrasMenuBar.
///
/// On macOS 27 extras no longer have their own window-server windows — the
/// system composites them inside MenuBarAgent — so identity and geometry
/// come entirely from Accessibility.
struct MenuBarItem: Identifiable, Hashable {
    /// Where the system currently renders the item.
    enum Placement: Hashable {
        /// Right of the system collapse button — actually rendered.
        case visible
        /// Left of the collapse button — in the system's overflow stack
        /// (several items may share overlapping positions there).
        case collapsed
        /// Sentinel position — removed by the system entirely.
        case parked
    }

    /// Always nil on macOS 27 — extras have no window-server windows anymore.
    let windowID: CGWindowID?

    /// Logical frame in screen coordinates (top-left origin). Collapsed
    /// items may overlap; parked items sit at sentinel positions.
    var frame: CGRect

    var isOnScreen: Bool { placement == .visible }
    var placement: Placement

    /// Unused on macOS 27 (kept for shape compatibility).
    var windowTitle: String = ""
    var windowOwnerPID: pid_t = 0

    /// Real owning app — direct from the app that publishes the extra.
    var appPID: pid_t?
    var appName: String?
    var appBundleID: String?
    var appIcon: NSImage?

    /// Accessibility attributes of the item.
    var axTitle: String?
    var axDescription: String?
    var axIdentifier: String?

    /// The AX element for the item (can perform AXPress — works even when
    /// the item is collapsed or parked, verified on macOS 27).
    var axElement: AXUIElement?

    /// Index among extras that are indistinguishable by
    /// (bundleID, title, identifier) — keeps stableID unique.
    var occurrence: Int = 0

    var id: String { stableID }

    /// Identity used for persistence. Positions drift and overlap, so the
    /// identity is app + AX attributes + occurrence index.
    var stableID: String {
        let base = appBundleID ?? appName ?? "unknown"
        return "\(base)|\(axTitle ?? "")|\(axIdentifier ?? "")|#\(occurrence)"
    }

    /// Name to show in the panel: prefer the app name; append the item's
    /// own title (e.g. badge text like "4") when it adds information.
    var displayName: String {
        let base = appName ?? axTitle ?? "未知项"
        if let axTitle, !axTitle.isEmpty, axTitle != base {
            return "\(base) · \(axTitle)"
        }
        return base
    }

    var isParked: Bool { placement == .parked }

    /// A visible item can be dragged into the system collapse zone.
    /// Apple's own extras (Siri/Spotlight/input menu/clock…) don't accept
    /// ⌘-drags on macOS 27 — identified by their com.apple.* bundle IDs
    /// since their AX identifiers are empty and titles are localized.
    var isMovable: Bool {
        placement == .visible &&
        !(appBundleID?.hasPrefix("com.apple.") ?? false)
    }

    var canBeHidden: Bool { isMovable }
}
