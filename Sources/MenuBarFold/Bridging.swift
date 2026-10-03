import ApplicationServices
import CoreGraphics
import Foundation

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
func CGSGetWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowCount")
func CGSGetOnScreenWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowList")
func CGSGetOnScreenWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
func CGSGetScreenRectForWindow(
    _ cid: CGSConnectionID,
    _ wid: CGWindowID,
    _ outRect: inout CGRect
) -> CGError

/// Private HIServices API: resolves the window server ID backing an
/// AXUIElement (works for menu bar items, even off-screen ones).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// Thin wrappers over private CGS window-server APIs.
enum Bridging {
    static var mainConnection: CGSConnectionID { CGSMainConnectionID() }

    /// Window IDs of all menu bar extras across all processes (hosted by ControlCenter on modern macOS).
    static func menuBarItemWindowIDs() -> [CGWindowID] {
        var count: Int32 = 0
        guard CGSGetWindowCount(mainConnection, 0, &count) == .success, count > 0 else {
            return []
        }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        var realCount: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(mainConnection, 0, count, &list, &realCount) == .success else {
            return []
        }
        return Array(list[..<Int(realCount)])
    }

    static func onScreenWindowIDs() -> Set<CGWindowID> {
        var count: Int32 = 0
        guard CGSGetOnScreenWindowCount(mainConnection, 0, &count) == .success, count > 0 else {
            return []
        }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        var realCount: Int32 = 0
        guard CGSGetOnScreenWindowList(mainConnection, 0, count, &list, &realCount) == .success else {
            return []
        }
        return Set(list[..<Int(realCount)])
    }

    /// Screen rect for a window. nil if the window no longer exists.
    static func frame(of windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        guard CGSGetScreenRectForWindow(mainConnection, windowID, &rect) == .success else {
            return nil
        }
        guard !rect.isNull, !rect.isInfinite, rect.width > 0 else {
            return nil
        }
        return rect
    }
}
