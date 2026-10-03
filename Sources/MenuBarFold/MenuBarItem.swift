import Cocoa
import ApplicationServices

/// A menu bar extra (status item) as seen through the window server,
/// optionally merged with accessibility info from the real owning app.
struct MenuBarItem: Identifiable, Hashable {
    /// Window ID of the item's backing window (owned by ControlCenter on modern macOS).
    /// nil if the item currently has no window (parked by the system, e.g. y == -1).
    let windowID: CGWindowID?

    /// The frame of the item's window in screen coordinates (top-left origin).
    /// For windowless items, the position reported by Accessibility.
    var frame: CGRect

    /// Whether the item's window is on screen.
    var isOnScreen: Bool

    /// The window title (kCGWindowName) — often "Item-0" or a bundle-id-ish string.
    var windowTitle: String

    /// PID that owns the item window (usually ControlCenter on modern macOS).
    var windowOwnerPID: pid_t

    /// Real owning app, resolved via per-app AXExtrasMenuBar matching.
    var appPID: pid_t?
    var appName: String?
    var appBundleID: String?
    var appIcon: NSImage?

    /// Accessibility attributes of the item.
    var axTitle: String?
    var axDescription: String?

    /// The AX element for the item (can perform AXPress).
    var axElement: AXUIElement?

    var id: String { stableID }

    /// Identity used for persistence. windowID changes across launches, so
    /// prefer app identity + title. Falls back to window title + x bucket.
    var stableID: String {
        if let appBundleID {
            return "\(appBundleID)|\(axTitle ?? "")|\(windowTitle)"
        }
        return "w|\(windowTitle)|\(Int(frame.minX) / 20)"
    }

    /// Name to show in the panel: prefer the app name; append the item's
    /// own title (e.g. badge text like "4") when it adds information.
    var displayName: String {
        let base = appName ?? axTitle ?? (windowTitle.isEmpty || windowTitle == "Item-0" ? "未知项" : windowTitle)
        if let axTitle, !axTitle.isEmpty, axTitle != base {
            return "\(base) · \(axTitle)"
        }
        return base
    }

    /// Whether the item has a live window that can be event-targeted.
    var hasWindow: Bool { windowID != nil }

    /// Whether the item is parked (removed from the bar by the system; AX says y < 0).
    var isParked: Bool { windowID == nil }

    var isMovable: Bool {
        Self.immovableWindowTitles.contains(windowTitle) == false &&
        Self.immovableAXIDs.contains(axDescription ?? "") == false
    }

    var canBeHidden: Bool {
        Self.nonHideableWindowTitles.contains(windowTitle) == false
    }

    // MARK: blacklists (mirroring Ice's known special items)

    private static let immovableWindowTitles: Set<String> = [
        "Clock", "Siri", "BentoBox-0", "Menubar",
    ]
    private static let immovableAXIDs: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
        "com.apple.menuextra.siri",
    ]
    private static let nonHideableWindowTitles: Set<String> = [
        "AudioVideoModule", "FaceTime", "MusicRecognition",
    ]
}
