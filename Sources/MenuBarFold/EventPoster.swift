import Cocoa

/// Synthetic CGEvent helpers for macOS 27+.
///
/// Menu bar extras no longer have their own window-server windows (they are
/// composited inside per-app full-width host windows), so events are routed
/// by coordinate hit-testing alone — no window-ID tagging.
enum EventPoster {
    /// Posts a ⌘-drag from one screen point to another. Used to reorder menu
    /// bar items — grabbing works by coordinate hit-test, so the item must be
    /// rendered (i.e. currently visible, not collapsed into the system tray).
    @MainActor
    static func drag(from: CGPoint, to: CGPoint) async {
        guard let source = configuredSource() else { return }
        guard
            let down = makeEvent(.leftMouseDown, at: from, flags: .maskCommand, source: source),
            let up = makeEvent(.leftMouseUp, at: to, flags: [], source: source)
        else { return }

        down.post(tap: .cgSessionEventTap)
        // The system grabs the item asynchronously; the grab needs a moment
        // to register before the dragged/up events arrive.
        try? await Task.sleep(for: .milliseconds(70))
        for step in 1...8 {
            let point = CGPoint(
                x: from.x + (to.x - from.x) * CGFloat(step) / 8,
                y: from.y + (to.y - from.y) * CGFloat(step) / 8
            )
            if let move = makeEvent(.leftMouseDragged, at: point, flags: .maskCommand, source: source) {
                move.post(tap: .cgSessionEventTap)
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        up.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func makeEvent(
        _ type: CGEventType,
        at point: CGPoint,
        flags: CGEventFlags,
        source: CGEventSource
    ) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.flags = flags
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
}
