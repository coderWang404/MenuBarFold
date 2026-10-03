import Cocoa
import ApplicationServices

/// A menu bar item discovered through an app's AXExtrasMenuBar — carries the
/// real owning app, which window-owner info can no longer provide (all extras
/// are hosted by ControlCenter on modern macOS).
///
/// Marked `@unchecked Sendable`: AXUIElement/NSImage are CF/ObjC reference
/// types that are safe to carry across threads as read-only values.
private struct AXExtraInfo: @unchecked Sendable {
    let element: AXUIElement
    /// Window ID resolved directly via _AXUIElementGetWindow — nil when the
    /// item currently has no window (parked by the system).
    let windowID: CGWindowID?
    let position: CGPoint
    let size: CGSize
    let title: String?
    let description: String?
    let identifier: String?
    let appPID: pid_t
    let appName: String?
    let appBundleID: String?
    let appIcon: NSImage?

    /// True when the position is a known "removed from menu bar" sentinel.
    var isParkedPosition: Bool {
        position.y < 0 || position == CGPoint(x: 0, y: 982)
    }
}

/// Tracks a folded item that was temporarily moved back on screen.
private struct TempShownContext {
    let itemID: String
    let windowID: CGWindowID
    let task: Task<Void, Never>
}

@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Items left of the fold divider (hidden by us).
    @Published private(set) var foldedItems: [MenuBarItem] = []

    /// Items right of the fold divider (managed by macOS; some may still be
    /// clipped off-screen by the notch / lack of space).
    @Published private(set) var otherItems: [MenuBarItem] = []

    /// Items that exist in an app's AXExtrasMenuBar but have no window
    /// (system removed them entirely; e.g. AX position y < 0).
    @Published private(set) var parkedItems: [MenuBarItem] = []

    /// Persistent IDs of items the user chose to fold. Reapplied on relaunch.
    @Published private(set) var foldedIDs: Set<String> {
        didSet { SettingsStore.shared.foldedIDs = foldedIDs }
    }

    /// Whether Accessibility permission is granted.
    @Published private(set) var isTrusted: Bool = false

    weak var appState: AppState?

    /// Resolved app identity per item window (filled by background AX passes).
    private var identityByWID = [CGWindowID: AXExtraInfo]()

    /// AX extras that currently have no item window (parked items).
    private var unmatchedAX = [AXExtraInfo]()

    private var tempShown = [String: TempShownContext]()
    private var refreshTimer: Timer?
    private var identityTimer: Timer?
    private var identityInFlight = false
    /// Window IDs ever observed; a *new* one triggers an identity pass.
    private var seenWIDs = Set<CGWindowID>()
    private var hasPlacedDivider = false
    private var hasRestoredFolds = false

    init() {
        foldedIDs = SettingsStore.shared.foldedIDs
    }

    func performSetup(appState: AppState) {
        self.appState = appState
        isTrusted = AXIsProcessTrusted()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.scheduleIdentityRefresh()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.scheduleIdentityRefresh()
            }
        }

        // Light geometry refresh — pure window-server calls, no AX IPC.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Slow identity refresh — names/icons drift rarely.
        identityTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleIdentityRefresh() }
        }

        // Debug/testing hooks via distributed notifications.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("MenuBarFold.Debug"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.userInfo?["cmd"] as? String else { return }
            let arg = note.userInfo?["id"] as? String
            Task { @MainActor in
                guard let self else { return }
                switch command {
                case "foldFirst":
                    if let item = self.otherItems.first(where: { $0.isMovable && $0.hasWindow }) {
                        await self.fold(item)
                    }
                case "unfoldFirst":
                    if let item = self.foldedItems.first {
                        await self.unfold(item)
                    }
                case "unfoldMatch":
                    if let needle = arg,
                       let item = self.foldedItems.first(where: { $0.stableID.contains(needle) }) {
                        await self.unfold(item)
                    }
                case "useFirst":
                    if let item = self.foldedItems.first {
                        await self.use(item)
                    }
                case "togglePanel":
                    self.appState?.panelController.toggle()
                default:
                    break
                }
            }
        }
    }

    /// Called once our control items exist in the menu bar.
    func controlItemsDidAppear() async {
        // Give the window server a beat to settle after item creation.
        try? await Task.sleep(for: .milliseconds(600))
        refresh()
        await placeDividerIfNeeded()
        appState?.controlItems.setDividerExpanded(true)
        refresh()
        await placeChevronIfNeeded()
        refresh()
        log("ready: folded=\(foldedItems.count) other=\(otherItems.count) parked=\(parkedItems.count)")
        // Persisted folds need resolved identities (stableID contains the
        // bundle ID), so the first AX pass must complete before restoring.
        await refreshIdentities()
        await restoreFolds()
    }

    // MARK: - Geometry refresh (fast, main thread)

    /// Rebuilds item lists from window-server state only — no AX IPC, so it's
    /// safe to call on every panel open / timer tick.
    func refresh() {
        let start = ContinuousClock.now
        isTrusted = AXIsProcessTrusted()

        let windowIDs = Bridging.menuBarItemWindowIDs()
        let infos = WindowInfo.allByWindowID()

        var items = [MenuBarItem]()
        var sawNewWindow = false

        for wid in windowIDs {
            guard let info = infos[wid] else { continue }
            if info.title == "Menubar" { continue }

            // Our own items: record their window-server IDs, skip management.
            if let title = info.title, title.hasPrefix(ControlItems.ownTitlePrefix) {
                if title.hasSuffix("divider") {
                    appState?.controlItems.dividerWindowID = wid
                } else if title.hasSuffix("chevron") {
                    appState?.controlItems.chevronWindowID = wid
                }
                continue
            }
            guard let frame = Bridging.frame(of: wid), frame.height >= 20, frame.height <= 60 else {
                continue
            }

            if !seenWIDs.contains(wid) {
                seenWIDs.insert(wid)
                sawNewWindow = true
            }

            let identity = identityByWID[wid]

            var item = MenuBarItem(
                windowID: wid,
                frame: frame,
                isOnScreen: info.isOnScreen,
                windowTitle: info.title ?? "",
                windowOwnerPID: info.ownerPID,
                appPID: nil, appName: nil, appBundleID: nil, appIcon: nil,
                axTitle: nil, axDescription: nil, axElement: nil
            )
            if let identity {
                apply(identity: identity, to: &item)
            }
            items.append(item)
        }

        // Parked items: AX extras that no longer have a window.
        parkedItems = unmatchedAX.map { extra in
            MenuBarItem(
                windowID: nil,
                frame: CGRect(origin: extra.position, size: extra.size),
                isOnScreen: false,
                windowTitle: "",
                windowOwnerPID: 0,
                appPID: extra.appPID,
                appName: extra.appName,
                appBundleID: extra.appBundleID,
                appIcon: extra.appIcon,
                axTitle: extra.title,
                axDescription: extra.description,
                axElement: extra.element
            )
        }

        // Section split by divider position.
        if let dividerWID = appState?.controlItems.dividerWindowID,
           let dividerFrame = Bridging.frame(of: dividerWID) {
            foldedItems = items
                .filter { $0.frame.maxX <= dividerFrame.minX }
                .sorted { $0.frame.minX < $1.frame.minX }
            otherItems = items
                .filter { $0.frame.maxX > dividerFrame.minX }
                .sorted { $0.frame.minX < $1.frame.minX }
        } else {
            items.sort { $0.frame.minX < $1.frame.minX }
            foldedItems = []
            otherItems = items
        }

        if sawNewWindow {
            scheduleIdentityRefresh()
        }

        let elapsed = ContinuousClock.now - start
        if elapsed > .milliseconds(50) {
            log("refresh took \(elapsed) (slow)")
        }
    }

    private func apply(identity: AXExtraInfo, to item: inout MenuBarItem) {
        item.appPID = identity.appPID
        item.appName = identity.appName
        item.appBundleID = identity.appBundleID
        item.appIcon = identity.appIcon
        item.axTitle = identity.title
        item.axDescription = identity.description
        item.axElement = identity.element
    }

    // MARK: - Identity refresh (slow, background thread)

    /// Kicks a background AX enumeration and merges results when done.
    /// Coalesces concurrent requests.
    private func scheduleIdentityRefresh() {
        guard !identityInFlight else { return }
        identityInFlight = true
        Task { await refreshIdentities() }
    }

    /// Runs one AX enumeration off the main thread and merges the result.
    private func refreshIdentities() async {
        let extras = await Task.detached {
            Self.enumerateAXExtras()
        }.value
        // Read frames NOW — the enumeration took seconds and items may have
        // moved (startup placement/repair). A stale snapshot mis-pairs.
        let windows = (foldedItems + otherItems).compactMap { item -> (wid: CGWindowID, frame: CGRect)? in
            guard let wid = item.windowID, let frame = Bridging.frame(of: wid) else { return nil }
            return (wid, frame)
        }
        mergeIdentities(extras: extras, windows: windows)
    }

    /// Matches freshly enumerated AX extras against item windows and rebuilds
    /// the published lists. Matching is primarily by the exact window ID that
    /// `_AXUIElementGetWindow` reports; position is only a fallback.
    private func mergeIdentities(extras: [AXExtraInfo], windows: [(wid: CGWindowID, frame: CGRect)]) {
        defer { identityInFlight = false }
        var newIdentities = [CGWindowID: AXExtraInfo]()
        var used = Set<Int>()
        let liveWIDs = Set(windows.map(\.wid))

        // Exact matches first (dead on macOS 26, kept for future-proofing).
        for (index, extra) in extras.enumerated() {
            if let wid = extra.windowID {
                newIdentities[wid] = extra
                used.insert(index)
            }
        }

        let sortedWindows = windows.sorted { $0.frame.minX > $1.frame.minX }

        // Strict position matches = confident anchors.
        for window in sortedWindows where newIdentities[window.wid] == nil {
            for (index, extra) in extras.enumerated()
            where !used.contains(index) && !extra.isParkedPosition {
                if extra.position.x >= window.frame.minX - 3,
                   extra.position.x <= window.frame.maxX + 3,
                   abs(extra.position.y - window.frame.minY) < 12 {
                    newIdentities[window.wid] = extra
                    used.insert(index)
                    break
                }
            }
        }

        // Anchor-constrained alignment for the remainder: a candidate extra
        // must sort order-consistently between the two confirmed anchors
        // bracketing this window. Ambiguous leftovers stay unidentified —
        // an "未知项" row is better than a wrong app name (and a wrong click).
        let anchored = sortedWindows.filter { newIdentities[$0.wid] != nil }
        for window in sortedWindows where newIdentities[window.wid] == nil {
            let rightAnchor = anchored.last(where: { $0.frame.minX > window.frame.minX })
            let leftAnchor = anchored.first(where: { $0.frame.minX < window.frame.minX })
            let xHi = rightAnchor.map { newIdentities[$0.wid]!.position.x } ?? .greatestFiniteMagnitude
            let xLo = leftAnchor.map { newIdentities[$0.wid]!.position.x } ?? -.greatestFiniteMagnitude

            var candidates = [(index: Int, distance: CGFloat)]()
            for (index, extra) in extras.enumerated()
            where !used.contains(index) && !extra.isParkedPosition {
                guard extra.position.x > xLo, extra.position.x < xHi,
                      abs(extra.position.y - window.frame.minY) < 12
                else { continue }
                candidates.append((index, abs(extra.position.x - window.frame.midX)))
            }
            candidates.sort { $0.distance < $1.distance }
            if let first = candidates.first, first.distance < 45,
               candidates.count == 1 || candidates[1].distance - first.distance > 20 {
                newIdentities[window.wid] = extras[first.index]
                used.insert(first.index)
            }
        }

        // Parked: extras with no live window at all (excluding our own
        // control items, which we deliberately skip during matching).
        let ownBundleID = Bundle.main.bundleIdentifier
        let unmatched = extras.enumerated().filter {
            !used.contains($0.offset)
                && !liveWIDs.contains($0.element.windowID ?? 0)
                && $0.element.appBundleID != ownBundleID
        }.map(\.element)

        log("identities: matched=\(newIdentities.count) parked=\(unmatched.count) extras=\(extras.count)")
        for window in sortedWindows {
            if let id = newIdentities[window.wid] {
                log("  pair wid=\(window.wid)@\(Int(window.frame.minX))..\(Int(window.frame.maxX)) → \(id.appName ?? "?")@\(Int(id.position.x))")
            } else {
                log("  pair wid=\(window.wid)@\(Int(window.frame.minX))..\(Int(window.frame.maxX)) → ???")
            }
        }
        identityByWID = newIdentities
        unmatchedAX = unmatched
        refresh()
    }

    /// Blocking AX enumeration over all running apps — call off the main thread.
    private nonisolated static func enumerateAXExtras() -> [AXExtraInfo] {
        var result = [AXExtraInfo]()
        let attrs = [
            kAXPositionAttribute, kAXSizeAttribute,
            kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
        ] as CFArray

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)

            var extrasBar: AnyObject?
            guard
                AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasBar) == .success,
                let extrasBar
            else {
                continue
            }
            var children: AnyObject?
            guard
                AXUIElementCopyAttributeValue(
                    extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &children
                ) == .success
            else {
                continue
            }
            let kids = children as? [AXUIElement] ?? []
            guard !kids.isEmpty else { continue }
            for child in kids {
                var values: CFArray?
                AXUIElementCopyMultipleAttributeValues(child, attrs, [], &values)
                let vals = values as? [Any] ?? []
                var position = CGPoint.zero
                var size = CGSize.zero
                if let v = axValue(vals, at: 0) { AXValueGetValue(v, .cgPoint, &position) }
                if let v = axValue(vals, at: 1) { AXValueGetValue(v, .cgSize, &size) }
                // Empty stubs (size 0 at a sentinel position) carry no info.
                if size == .zero { continue }
                var wid: CGWindowID = 0
                let windowID: CGWindowID? =
                    _AXUIElementGetWindow(child, &wid) == .success && wid != 0 ? wid : nil
                result.append(AXExtraInfo(
                    element: child,
                    windowID: windowID,
                    position: position,
                    size: size,
                    title: vals[safe: 2] as? String,
                    description: vals[safe: 3] as? String,
                    identifier: vals[safe: 4] as? String,
                    appPID: app.processIdentifier,
                    appName: app.localizedName,
                    appBundleID: bundleID,
                    appIcon: app.icon
                ))
            }
        }
        return result
    }

    private nonisolated static func axValue(_ vals: [Any], at index: Int) -> AXValue? {
        guard index < vals.count else { return nil }
        let v = vals[index] as CFTypeRef
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    // MARK: - Divider placement

    /// Moves the divider to the left edge so nothing is folded initially.
    private func placeDividerIfNeeded() async {
        guard !hasPlacedDivider, let dividerWID = appState?.controlItems.dividerWindowID else {
            return
        }
        guard let leftmost = otherItems.min(by: { $0.frame.minX < $1.frame.minX }),
              let leftFrame = Bridging.frame(of: leftmost.windowID ?? 0)
        else {
            return
        }
        guard let dividerFrame = Bridging.frame(of: dividerWID),
              dividerFrame.minX > leftFrame.minX
        else {
            hasPlacedDivider = true
            return
        }
        _ = await EventPoster.move(
            item: ownItemAsMenuBarItem(dividerWID),
            to: .leftOf(windowID: leftmost.windowID ?? 0, point: CGPoint(x: leftFrame.minX, y: leftFrame.midY))
        )
        hasPlacedDivider = true
    }

    /// Moves our chevron into the visible part of the menu bar (right of the
    /// notch / app-menu boundary), if it isn't already.
    private func placeChevronIfNeeded() async {
        guard let chevronWID = appState?.controlItems.chevronWindowID,
              let chevronFrame = Bridging.frame(of: chevronWID)
        else {
            return
        }
        let boundary = rightContentBoundary()
        if chevronFrame.minX > boundary, chevronFrame.maxX <= (NSScreen.main?.frame.maxX ?? .infinity) {
            return
        }
        let width = max(chevronFrame.width, 24)
        let candidates = otherItems
            .filter { $0.isOnScreen && $0.windowID != nil }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard
            let target = candidates.first(where: { $0.frame.minX - width > boundary + 4 })
                ?? candidates.first,
            let targetWID = target.windowID,
            let targetFrame = Bridging.frame(of: targetWID)
        else {
            return
        }
        _ = await EventPoster.move(
            item: ownItemAsMenuBarItem(chevronWID),
            to: .leftOf(windowID: targetWID, point: CGPoint(x: targetFrame.minX, y: targetFrame.midY))
        )
    }

    /// Builds a MenuBarItem-shaped view of one of our own control items.
    private func ownItemAsMenuBarItem(_ windowID: CGWindowID) -> MenuBarItem {
        let info = WindowInfo.allByWindowID()[windowID]
        return MenuBarItem(
            windowID: windowID,
            frame: Bridging.frame(of: windowID) ?? .zero,
            isOnScreen: true,
            windowTitle: info?.title ?? "",
            windowOwnerPID: info?.ownerPID ?? 0,
            appPID: nil, appName: nil, appBundleID: nil, appIcon: nil,
            axTitle: nil, axDescription: nil, axElement: nil
        )
    }

    // MARK: - Fold / unfold

    func fold(_ item: MenuBarItem) async {
        guard let dividerWID = appState?.controlItems.dividerWindowID,
              let dividerFrame = Bridging.frame(of: dividerWID)
        else { return }
        log("fold \(item.stableID) to leftOf divider@\(dividerFrame.minX)")
        let ok = await EventPoster.move(
            item: item,
            to: .leftOf(
                windowID: dividerWID,
                point: CGPoint(x: dividerFrame.minX, y: dividerFrame.midY)
            )
        )
        log("fold result=\(ok)")
        if ok {
            foldedIDs.insert(item.stableID)
        }
        refresh()
    }

    func unfold(_ item: MenuBarItem) async {
        guard let dividerWID = appState?.controlItems.dividerWindowID,
              let dividerFrame = Bridging.frame(of: dividerWID)
        else { return }

        // Drop next to the visible cluster — landing right of the divider
        // would put the item underneath the app's menus (x ≈ 0-250).
        let destination = visibleDropDestination() ?? .rightOf(
            windowID: dividerWID,
            point: CGPoint(x: dividerFrame.maxX, y: dividerFrame.midY)
        )

        log("unfold \(item.stableID) to \(destination)")
        let ok = await EventPoster.move(item: item, to: destination)
        log("unfold result=\(ok)")
        if ok {
            foldedIDs.remove(item.stableID)
        }
        refresh()
    }

    /// Drop destination adjacent to the visible item cluster (the leftmost
    /// item that is actually rendered outside the app-menu region).
    private func visibleDropDestination() -> EventPoster.MoveDestination? {
        let boundary = rightContentBoundary()
        guard
            let target = otherItems
                .filter({ $0.isOnScreen && $0.windowID != nil && $0.frame.minX >= boundary - 4 })
                .min(by: { $0.frame.minX < $1.frame.minX }),
            let targetWID = target.windowID,
            let targetFrame = Bridging.frame(of: targetWID)
        else {
            return nil
        }
        return .leftOf(
            windowID: targetWID,
            point: CGPoint(x: targetFrame.minX, y: targetFrame.midY)
        )
    }

    /// Re-applies persisted folds after launch, then normalizes: anything
    /// physically folded that isn't in the persisted set (items drift left
    /// when the divider's slot moves between launches) gets unfolded, so the
    /// folded set always equals exactly what the user chose.
    private func restoreFolds() async {
        guard !hasRestoredFolds else { return }
        hasRestoredFolds = true
        for item in otherItems where foldedIDs.contains(item.stableID) {
            await fold(item)
        }
        refresh()
        for item in foldedItems where !foldedIDs.contains(item.stableID) {
            await unfold(item)
        }

        // Repair: items rendered on top of the app-menu region (left behind
        // by earlier versions' bad drop target, or manually dragged there by
        // the user) get moved back next to the visible cluster.
        let boundary = rightContentBoundary()
        for item in otherItems
        where item.isOnScreen && item.frame.minX < boundary - 20 && item.windowID != nil {
            if let destination = visibleDropDestination() {
                log("repair misplaced \(item.stableID)@\(item.frame.minX) → \(destination)")
                _ = await EventPoster.move(item: item, to: destination)
            }
        }
        refresh()
    }

    // MARK: - Use an item

    /// Activates an item: clicks it in place if visible, otherwise temporarily
    /// moves it into the visible area, clicks it, and rehides it later.
    func use(_ row: MenuBarItem) async {
        // The row may carry a stale window ID (items get recreated and IDs
        // reused); re-resolve against the CURRENT lists — by stableID first,
        // then by the window ID itself. Never click a stale row's window.
        refresh()
        let current = foldedItems + otherItems + parkedItems
        let item = current.first(where: { $0.stableID == row.stableID })
            ?? current.first(where: { $0.windowID != nil && $0.windowID == row.windowID })
            ?? row
        log("use \(item.stableID) wid=\(String(describing: item.windowID)) folded=\(foldedItems.contains { $0.id == item.id }) onscreen=\(item.isOnScreen)")
        guard let wid = item.windowID, let frame = Bridging.frame(of: wid) else {
            // Parked item: try a direct AX press — the app may still respond.
            if let element = item.axElement {
                AXUIElementPerformAction(element, "AXPress" as CFString)
            }
            return
        }

        let isFolded = foldedItems.contains { $0.id == item.id }
        if !isFolded, item.isOnScreen {
            _ = await EventPoster.click(item: item)
            return
        }

        // Temporarily show: find a visible item with enough room to its left
        // to fit our item while staying clear of the notch / app menus.
        refresh()
        let boundary = rightContentBoundary()
        let candidates = otherItems
            .filter { $0.isOnScreen && $0.windowID != nil }
            .sorted { $0.frame.minX < $1.frame.minX }
        let itemWidth = max(frame.width, 20)
        guard
            let target = candidates.first(where: { $0.frame.minX - itemWidth > boundary + 4 })
                ?? candidates.first
        else {
            log("use: no room to show \(item.stableID)")
            return
        }
        guard let targetFrame = Bridging.frame(of: target.windowID!) else { return }

        log("tempShow \(item.stableID) leftOf \(target.stableID)@\(targetFrame.minX), boundary=\(boundary)")
        let shown = await EventPoster.move(
            item: item,
            to: .leftOf(
                windowID: target.windowID!,
                point: CGPoint(x: targetFrame.minX, y: targetFrame.midY)
            )
        )
        guard shown else { return }

        try? await Task.sleep(for: .milliseconds(60))
        var fresh = item
        fresh.frame = Bridging.frame(of: wid) ?? item.frame
        _ = await EventPoster.click(item: fresh)

        scheduleRehide(itemID: item.id, windowID: wid)
        refresh()
    }

    /// Left edge that a temporarily shown item must stay right of
    /// (notch's right edge, or the end of the foreground app's menus).
    private func rightContentBoundary() -> CGFloat {
        if let area = NSScreen.main?.auxiliaryTopRightArea {
            return area.minX + 8
        }
        return appMenuBarMaxX() + 8
    }

    /// maxX of the frontmost app's application menus (for non-notch displays).
    private func appMenuBarMaxX() -> CGFloat {
        guard let front = NSWorkspace.shared.frontmostApplication else { return 0 }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var menuBar: AnyObject?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBar) == .success,
            let menuBar
        else {
            return 0
        }
        var children: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children
            ) == .success
        else {
            return 0
        }
        var maxX: CGFloat = 0
        for child in children as? [AXUIElement] ?? [] {
            var posRef: AnyObject?
            var sizeRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
            var p = CGPoint.zero
            var s = CGSize.zero
            if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &p) }
            if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &s) }
            maxX = max(maxX, p.x + s.width)
        }
        return maxX
    }

    private func scheduleRehide(itemID: String, windowID: CGWindowID) {
        tempShown[itemID]?.task.cancel()
        let interval = SettingsStore.shared.tempShowInterval
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            await self.rehide(windowID: windowID, itemID: itemID)
        }
        tempShown[itemID] = TempShownContext(itemID: itemID, windowID: windowID, task: task)
    }

    /// Moves a temporarily shown item back into the folded area.
    private func rehide(windowID: CGWindowID, itemID: String) async {
        defer { tempShown.removeValue(forKey: itemID) }
        guard let dividerWID = appState?.controlItems.dividerWindowID,
              let dividerFrame = Bridging.frame(of: dividerWID),
              let itemFrame = Bridging.frame(of: windowID)
        else {
            return
        }
        let infos = WindowInfo.allByWindowID()[windowID]
        let item = MenuBarItem(
            windowID: windowID,
            frame: itemFrame,
            isOnScreen: true,
            windowTitle: infos?.title ?? "",
            windowOwnerPID: infos?.ownerPID ?? 0,
            appPID: nil, appName: nil, appBundleID: nil, appIcon: nil,
            axTitle: nil, axDescription: nil, axElement: nil
        )
        _ = await EventPoster.move(
            item: item,
            to: .leftOf(
                windowID: dividerWID,
                point: CGPoint(x: dividerFrame.minX, y: dividerFrame.midY)
            )
        )
        refresh()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
