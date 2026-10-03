import Cocoa

/// A snapshot of a window's metadata from `CGWindowListCopyWindowInfo`.
struct WindowInfo: Hashable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String?
    let title: String?
    let layer: Int
    let isOnScreen: Bool
    let frame: CGRect

    init?(dictionary: [String: Any]) {
        guard
            let windowID = dictionary[kCGWindowNumber as String] as? CGWindowID,
            let ownerPID = dictionary[kCGWindowOwnerPID as String] as? Int,
            let layer = dictionary[kCGWindowLayer as String] as? Int
        else {
            return nil
        }
        self.windowID = windowID
        self.ownerPID = pid_t(ownerPID)
        self.layer = layer
        self.title = dictionary[kCGWindowName as String] as? String
        self.ownerName = dictionary[kCGWindowOwnerName as String] as? String
        self.isOnScreen = dictionary[kCGWindowIsOnscreen as String] as? Bool ?? false
        var frame = CGRect.zero
        if let bounds = dictionary[kCGWindowBounds as String] as? [String: CGFloat] {
            frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
        }
        self.frame = frame
    }

    /// All windows on the system keyed by window ID.
    static func allByWindowID() -> [CGWindowID: WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var result = [CGWindowID: WindowInfo]()
        for dict in list {
            if let info = WindowInfo(dictionary: dict) {
                result[info.windowID] = info
            }
        }
        return result
    }
}
