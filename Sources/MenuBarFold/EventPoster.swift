import Cocoa

/// Posts synthetic ⌘-drag / click events targeted at specific menu bar item
/// windows, using private window-routing event fields (the same approach as
/// the open-source Ice app). Because events carry the target window ID
/// explicitly, the cursor position does not need to be on screen — which is
/// what makes it possible to grab items that are clipped off-screen.
enum EventPoster {
    /// Private event field that carries the target window ID.
    private static let windowIDField = CGEventField(rawValue: 0x33)!

    /// Point used as the "grab" location for item moves (does not need to be on screen).
    private static let grabPoint = CGPoint(x: 20_000, y: 20_000)

    /// Where an item should be dropped relative to a target item.
    enum MoveDestination {
        case leftOf(windowID: CGWindowID, point: CGPoint)
        case rightOf(windowID: CGWindowID, point: CGPoint)

        var targetWindowID: CGWindowID {
            switch self {
            case .leftOf(let wid, _), .rightOf(let wid, _): wid
            }
        }
        var point: CGPoint {
            switch self {
            case .leftOf(_, let p), .rightOf(_, let p): p
            }
        }
    }

    private static func makeEvent(
        _ type: CGEventType,
        at point: CGPoint,
        taggedTo windowID: CGWindowID,
        ownerPID: pid_t,
        flags: CGEventFlags,
        source: CGEventSource,
        clickState: Int64 = 0
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return nil
        }
        event.flags = flags
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        event.setIntegerValueField(windowIDField, value: Int64(windowID))
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        return event
    }

    private static func configuredSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        source.localEventsSuppressionInterval = 0
        let permitAll: CGEventFilterMask = [
            .permitLocalMouseEvents,
            .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents,
        ]
        for state in [
            CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,
            .eventSuppressionStateSuppressionInterval,
        ] {
            source.setLocalEventsFilterDuringSuppressionState(permitAll, state: state)
        }
        return source
    }

    /// Waits for the given window's frame to change, up to `timeout`.
    /// Returns true if a change was observed. A timeout is not necessarily a
    /// failure — the system may not move the window until the drop.
    private static func waitForFrameChange(
        of windowID: CGWindowID,
        timeout: Duration
    ) async -> Bool {
        let initial = Bridging.frame(of: windowID)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Bridging.frame(of: windowID) != initial {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Moves an item next to a destination item using a synthetic ⌘-drag.
    /// Returns true if the item ended up adjacent to the destination.
    @MainActor
    static func move(item: MenuBarItem, to destination: MoveDestination) async -> Bool {
        guard let itemWID = item.windowID else { return false }
        guard let source = configuredSource() else { return false }

        let endPoint = destination.point
        let targetWID = destination.targetWindowID

        guard
            let down = makeEvent(
                .leftMouseDown,
                at: grabPoint,
                taggedTo: itemWID,
                ownerPID: item.windowOwnerPID,
                flags: .maskCommand,
                source: source
            ),
            let up = makeEvent(
                .leftMouseUp,
                at: endPoint,
                taggedTo: targetWID,
                ownerPID: item.windowOwnerPID,
                flags: [],
                source: source
            )
        else {
            return false
        }

        down.post(tap: .cgSessionEventTap)
        // The system grabs the item asynchronously; its frame does not change
        // during the grab, but the grab needs a moment to register before
        // the up arrives.
        try? await Task.sleep(for: .milliseconds(70))
        up.post(tap: .cgSessionEventTap)

        // Wait for the item to land.
        _ = await waitForFrameChange(of: itemWID, timeout: .milliseconds(500))
        try? await Task.sleep(for: .milliseconds(30))

        guard let newFrame = Bridging.frame(of: itemWID) else {
            return false
        }
        switch destination {
        case .leftOf:
            return abs(newFrame.maxX - endPoint.x) < 40 || newFrame != item.frame
        case .rightOf:
            return abs(newFrame.minX - endPoint.x) < 40 || newFrame != item.frame
        }
    }

    /// Performs a left-click on an item that is currently on screen.
    @MainActor
    static func click(item: MenuBarItem) async -> Bool {
        guard
            let itemWID = item.windowID,
            let frame = Bridging.frame(of: itemWID),
            let source = configuredSource(),
            let down = makeEvent(
                .leftMouseDown,
                at: CGPoint(x: frame.midX, y: frame.midY),
                taggedTo: itemWID,
                ownerPID: item.windowOwnerPID,
                flags: [],
                source: source,
                clickState: 1
            ),
            let up = makeEvent(
                .leftMouseUp,
                at: CGPoint(x: frame.midX, y: frame.midY),
                taggedTo: itemWID,
                ownerPID: item.windowOwnerPID,
                flags: [],
                source: source,
                clickState: 1
            )
        else {
            return false
        }
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(40))
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
