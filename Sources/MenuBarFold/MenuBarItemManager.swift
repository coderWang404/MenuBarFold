import Cocoa
import ApplicationServices

/// A menu bar extra discovered through an app's AXExtrasMenuBar.
///
/// Marked `@unchecked Sendable`: AXUIElement/NSImage are CF/ObjC reference
/// types that are safe to carry across threads as read-only values.
private struct AXExtraInfo: @unchecked Sendable {
    let element: AXUIElement
    let position: CGPoint
    let size: CGSize
    let title: String?
    let description: String?
    let identifier: String?
    let role: String?
    let appPID: pid_t
    let appName: String?
    let appBundleID: String?
    let appIcon: NSImage?
    /// Index among extras identical by (bundleID, title, identifier).
    var occurrence: Int = 0

    /// Sentinel positions for items removed from the bar by the system:
    /// (-1, 970+), (7, 986.5), offscreen-left (x < 0) from legacy moves.
    var isParkedPosition: Bool {
        position.x < 0 || position.y < 0 || position.y > 45
    }

    var stableID: String {
        let base = appBundleID ?? appName ?? "unknown"
        return "\(base)|\(title ?? "")|\(identifier ?? "")|#\(occurrence)"
    }
}

/// Enumerates menu bar extras purely via Accessibility, classifies them
/// against the system's collapse button, and performs fold/use via
/// coordinate ⌘-drag and AXPress.
///
/// macOS 27 architecture: MenuBarAgent composites all extras itself; the
/// overflow stack lives left of its ⌄ button (multiple items share
/// overlapping positions there — they are not hit-testable, so unfolding
/// is best-effort; AXPress remains the reliable way to use them).
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Items in the system's overflow zone (left of the ⌄ button).
    @Published private(set) var collapsedItems: [MenuBarItem] = []

    /// Items rendered in the bar (right of the ⌄ button).
    @Published private(set) var visibleItems: [MenuBarItem] = []

    /// Items at sentinel positions (fully removed by the system).
    @Published private(set) var parkedItems: [MenuBarItem] = []

    /// Persistent IDs of items the user chose to fold.
    @Published private(set) var foldedIDs: Set<String> {
        didSet { SettingsStore.shared.foldedIDs = foldedIDs }
    }

    /// Whether Accessibility permission is granted.
    @Published private(set) var isTrusted: Bool = false

    /// Transient footer message (e.g. when an unfold can't be automated).
    @Published private(set) var notice: String?

    /// Whether our own chevron is parked at the system's sentinel
    /// position (not rendered anywhere in the bar).
    @Published private(set) var ownChevronParked: Bool = false

    weak var appState: AppState?

    /// Left edge of the system collapse ⌄ button — items left of it are
    /// in the overflow zone. Recomputed on every AX pass; falls back to
    /// a conservative estimate when the button isn't published yet.
    private var collapseBoundary: CGFloat = 880

    private var refreshInFlight = false
    private var refreshAgain = false
    private var refreshTimer: Timer?
    private var hasRestoredFolds = false
    private var noticeTask: Task<Void, Never>?

    init() {
        foldedIDs = SettingsStore.shared.foldedIDs
    }

    func performSetup(appState: AppState) {
        self.appState = appState
        isTrusted = AXIsProcessTrusted()

        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }

        // Positions drift as the system manages the bar; AX enumeration is
        // a background pass so even an 8s cadence stays off the main thread.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
                    if let item = self.visibleItems.first(where: \.isMovable) {
                        await self.fold(item)
                    }
                case "unfoldFirst":
                    if let item = self.collapsedItems.first {
                        await self.unfold(item)
                    }
                case "unfoldMatch":
                    if let needle = arg,
                       let item = self.collapsedItems.first(where: {
                           $0.stableID.localizedCaseInsensitiveContains(needle)
                           || $0.displayName.localizedCaseInsensitiveContains(needle)
                       }) {
                        await self.unfold(item)
                    }
                case "useFirst":
                    if let item = self.collapsedItems.first {
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
        try? await Task.sleep(for: .milliseconds(800))
        await refreshNow()
        await restoreFolds()
        log("ready: visible=\(visibleItems.count) collapsed=\(collapsedItems.count) parked=\(parkedItems.count) boundary=\(Int(collapseBoundary))")
    }

    // MARK: - Refresh (AX enumeration, background)

    /// Kicks an asynchronous AX enumeration; returns immediately. Safe to
    /// call on every panel open / timer tick — requests coalesce.
    func refresh() {
        isTrusted = AXIsProcessTrusted()
        guard !refreshInFlight else {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        Task { await finishRefresh() }
    }

    /// Awaitable variant for launch sequencing.
    private func refreshNow() async {
        isTrusted = AXIsProcessTrusted()
        if refreshInFlight { return }
        refreshInFlight = true
        await finishRefresh()
    }

    private func finishRefresh() async {
        let extras = await Task.detached { Self.enumerateAXExtras() }.value
        refreshInFlight = false
        if refreshAgain {
            refreshAgain = false
            refresh()
            return
        }
        apply(extras: extras)
    }

    private func apply(extras: [AXExtraInfo]) {
        let ownBundleID = Bundle.main.bundleIdentifier
        var ownPositions = [CGPoint]()
        var boundary: CGFloat?
        var collapsed = [MenuBarItem]()
        var visible = [MenuBarItem]()
        var parked = [MenuBarItem]()

        for extra in extras {
            // Our own chevron — feed its position to ControlItems for
            // panel anchoring and parked-state recovery, never list it.
            if extra.appBundleID == ownBundleID {
                ownPositions.append(extra.position)
                continue
            }
            // MenuBarAgent's own chrome (clock/battery/CC groups + the ⌄
            // button) isn't user-manageable; the button marks the boundary.
            if extra.appBundleID == "com.apple.MenuBarAgent" {
                if extra.role == "AXButton", extra.size.width < 60 {
                    boundary = min(boundary ?? .greatestFiniteMagnitude, extra.position.x)
                }
                continue
            }
            if extra.size == .zero { continue }

            let item = MenuBarItem(
                windowID: nil,
                frame: CGRect(origin: extra.position, size: extra.size),
                placement: .visible, // provisional, classified below
                appPID: extra.appPID,
                appName: extra.appName,
                appBundleID: extra.appBundleID,
                appIcon: extra.appIcon,
                axTitle: extra.title,
                axDescription: extra.description,
                axIdentifier: extra.identifier,
                axElement: extra.element,
                occurrence: extra.occurrence
            )
            if extra.isParkedPosition {
                var it = item; it.placement = .parked
                parked.append(it)
            } else {
                // Classification needs the boundary; collect, split after.
                visible.append(item) // staging — real split below
            }
        }

        if let boundary {
            collapseBoundary = boundary
        } else {
            // No collapse button published yet — everything is visible.
            collapseBoundary = NSScreen.main?.auxiliaryTopRightArea?.minX ?? 880
        }

        // `visible` above was a staging list; split it against the boundary.
        let staged = visible
        visible = staged.filter { $0.frame.minX >= collapseBoundary - 1 }
        collapsed = staged.filter { $0.frame.minX < collapseBoundary - 1 }.map {
            var it = $0; it.placement = .collapsed; return it
        }
        visible.sort { $0.frame.minX > $1.frame.minX }
        collapsed.sort { $0.frame.minX < $1.frame.minX }
        parked.sort { ($0.appName ?? "") < ($1.appName ?? "") }

        collapsedItems = collapsed
        visibleItems = visible
        parkedItems = parked
        appState?.controlItems.observeOwnExtras(positions: ownPositions)

        ownChevronParked = !ownPositions.isEmpty && ownPositions.allSatisfy { isParked($0) }
    }

    /// Re-runs the chevron recovery on demand (footer button). Deliberately
    /// NOT automatic on launch: restarting the system agents re-randomizes
    /// the whole bar layout and has been observed knocking *other* apps'
    /// live items into the parked sentinel — too destructive to fire
    /// unattended.
    func retryChevronRecovery() {
        Task { await recoverChevron() }
    }

    /// Opens System Settings → 菜单栏 (the pane hosting the "允许在菜单栏
    /// 显示" list) so the user can inspect the app's allow switch.
    func openMenuBarSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
        )
    }

    // MARK: - Fold / unfold

    /// Folds a visible item into the system overflow zone (left of ⌄).
    ///
    /// Primary path: AX-set the position attribute — macOS 27 accepts it
    /// (returns an error code yet still applies). Fallback: coordinate
    /// ⌘-drag from the item's *rendered* position (AX positions are logical
    /// and drift from the rendered slot after the system rebalances).
    func fold(_ item: MenuBarItem) async {
        guard item.placement == .visible, item.isMovable else { return }
        let collapsedPoint = CGPoint(x: collapseBoundary - 30, y: 4.5)

        if let el = item.axElement {
            Self.setAXPosition(el, to: collapsedPoint)
        }
        var moved = await positionCheck(item) { pos, _ in
            pos.x < self.collapseBoundary - 1 || self.isParked(pos)
        }
        if !moved {
            guard let grab = await renderedCenterX(of: item) else {
                log("fold \(item.stableID): item not rendered at any hit position")
                showNotice("找不到「\(item.displayName)」的渲染位置")
                return
            }
            log("fold-drag \(item.stableID) \(Int(grab))→\(Int(collapsedPoint.x))")
            await EventPoster.drag(from: CGPoint(x: grab, y: 16.5), to: collapsedPoint)
            moved = await positionCheck(item) { pos, _ in
                pos.x < self.collapseBoundary - 1 || self.isParked(pos)
            }
        }
        log("fold \(item.stableID) moved=\(moved)")
        if moved { foldedIDs.insert(item.stableID) }
        else { showNotice("未能折叠「\(item.displayName)」") }
        refresh()
    }

    /// Best-effort unfold: AX-set position, then a coordinate drag out of
    /// the overflow zone. Stacked items usually can't be hit-tested — when
    /// that fails we tell the user to use the system's ⌄ tray.
    func unfold(_ item: MenuBarItem) async {
        let target = CGPoint(x: collapseBoundary + 60, y: 4.5)

        // Attempt 1: AX-set the position attribute — verified working on
        // macOS 27 even for items stacked in the overflow zone.
        if let el = item.axElement {
            Self.setAXPosition(el, to: target)
        }
        var moved = await positionCheck(item) { pos, _ in
            pos.x >= self.collapseBoundary - 1 && !self.isParked(pos)
        }

        // Attempt 2: coordinate ⌘-drag out of the overflow zone (items in
        // the zone usually aren't hit-testable, so this rarely lands).
        if !moved {
            await EventPoster.drag(
                from: CGPoint(x: item.frame.midX, y: item.frame.midY),
                to: target
            )
            moved = await positionCheck(item) { pos, _ in
                pos.x >= self.collapseBoundary - 1 && !self.isParked(pos)
            }
        }
        log("unfold \(item.stableID) moved=\(moved)")
        if moved {
            foldedIDs.remove(item.stableID)
        } else {
            showNotice("无法自动展开「\(item.displayName)」— 请点击菜单栏 ⌄ 手动拖出")
        }
        refresh()
    }

    /// Re-applies persisted folds on launch: items the user folded that the
    /// system currently renders get dragged back into the overflow zone.
    private func restoreFolds() async {
        guard !hasRestoredFolds else { return }
        hasRestoredFolds = true
        for item in visibleItems where foldedIDs.contains(item.stableID) && item.isMovable {
            await fold(item)
        }
    }

    /// Recovers a chevron the system parked at the sentinel position.
    ///
    /// On macOS 27 every freshly created NSStatusItem is parked offscreen;
    /// neither `isVisible`, position writes, nor recreation bring it back.
    /// The only observed recovery is restarting the agents that own the
    /// menu-bar layout — ControlCenter first, then MenuBarAgent (launchd
    /// respawns both; the bar flickers once). After the re-layout our item
    /// lands in the collapse cluster as a normal live item, so we AX-write
    /// it into the visible strip.
    private func recoverChevron() async {
        log("chevron parked — restarting ControlCenter/MenuBarAgent")
        await Task.detached { Self.restartMenuBarAgents() }.value
        try? await Task.sleep(for: .seconds(2))
        if let own = await Self.ownExtra(), !own.isParkedPosition,
           let leftmost = visibleItems.min(by: { $0.frame.minX < $1.frame.minX }) {
            Self.setAXPosition(
                own.element, to: CGPoint(x: leftmost.frame.minX - 30, y: 4.5)
            )
        }
        refresh()
        // Wait for the relayout to settle, then report the outcome.
        try? await Task.sleep(for: .seconds(4))
        if let own = await Self.ownExtra() {
            log("chevron recovery: item now at \(own.position)")
            if own.isParkedPosition {
                showNotice("图标仍未恢复 — 试试重启 Mac，或在 系统设置›菜单栏 中检查")
            }
        }
    }

    /// Kills the agents that own menu-bar layout; launchd respawns them.
    private nonisolated static func restartMenuBarAgents() {
        for name in ["ControlCenter", "MenuBarAgent"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [name]
            try? p.run()
            p.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    /// Reads our own app's extras (the chevron).
    private nonisolated static func ownExtra() async -> AXExtraInfo? {
        await Task.detached {
            guard let bid = Bundle.main.bundleIdentifier,
                  let app = NSRunningApplication
                      .runningApplications(withBundleIdentifier: bid).first
            else { return nil }
            return extrasForApp(app).first
        }.value
    }

    // MARK: - Use an item

    /// Activates an item via AXPress. On macOS 27 this works even for items
    /// in the system overflow zone — the app still opens its menu.
    func use(_ row: MenuBarItem) async {
        // Re-resolve the row against the current lists — stale rows may
        // carry dead AX elements after a move.
        let current = collapsedItems + visibleItems + parkedItems
        let item = current.first(where: { $0.stableID == row.stableID }) ?? row
        log("use \(item.stableID)")

        // Prefer a freshly fetched element for the owning app — the stored
        // element goes stale when the system rebuilds its extras.
        if let bundleID = item.appBundleID {
            let key = Self.key(of: item)
            if let live = await Self.findExtra(bundleID: bundleID, matching: key) {
                AXUIElementPerformAction(live.element, kAXPressAction as CFString)
                return
            }
        }
        if let element = item.axElement {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    // MARK: - AX enumeration

    /// Blocking AX enumeration over all running apps — call off the main thread.
    private nonisolated static func enumerateAXExtras() -> [AXExtraInfo] {
        var result = [AXExtraInfo]()
        for app in NSWorkspace.shared.runningApplications {
            guard app.bundleIdentifier != nil else { continue }
            result.append(contentsOf: extrasForApp(app))
        }
        // Disambiguate identical extras from the same app.
        var seen = [String: Int]()
        for i in result.indices {
            let key = "\(result[i].appBundleID ?? "")|\(result[i].title ?? "")|\(result[i].identifier ?? "")"
            let n = seen[key, default: 0]
            result[i].occurrence = n
            seen[key] = n + 1
        }
        return result
    }

    /// Extras of one app — used for full passes and for per-item re-checks.
    private nonisolated static func extrasForApp(_ app: NSRunningApplication) -> [AXExtraInfo] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var extrasBar: AnyObject?
        guard
            AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasBar) == .success,
            let extrasBar
        else { return [] }
        var children: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &children
            ) == .success
        else { return [] }

        let attrs = [
            kAXPositionAttribute, kAXSizeAttribute,
            kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
            kAXRoleAttribute,
        ] as CFArray
        var out = [AXExtraInfo]()
        for child in children as? [AXUIElement] ?? [] {
            var values: CFArray?
            AXUIElementCopyMultipleAttributeValues(child, attrs, [], &values)
            let vals = values as? [Any] ?? []
            var position = CGPoint.zero
            var size = CGSize.zero
            if let v = axValue(vals, at: 0) { AXValueGetValue(v, .cgPoint, &position) }
            if let v = axValue(vals, at: 1) { AXValueGetValue(v, .cgSize, &size) }
            out.append(AXExtraInfo(
                element: child,
                position: position,
                size: size,
                title: vals[safe: 2] as? String,
                description: vals[safe: 3] as? String,
                identifier: vals[safe: 4] as? String,
                role: vals[safe: 5] as? String,
                appPID: app.processIdentifier,
                appName: app.localizedName,
                appBundleID: app.bundleIdentifier,
                appIcon: app.icon
            ))
        }
        return out
    }

    /// Identity key used to find the same logical extra in a fresh pass.
    private nonisolated static func key(of item: MenuBarItem) -> String {
        "\(item.axTitle ?? "")|\(item.axIdentifier ?? "")|\(item.occurrence)"
    }

    /// Re-reads one app's extras and returns the element whose identity key
    /// matches the item (occurrence counted per that app's extras order).
    private nonisolated static func findExtra(
        bundleID: String, matching key: String
    ) async -> AXExtraInfo? {
        await Task.detached {
            guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleID })
            else { return nil }
            var seen = [String: Int]()
            for extra in extrasForApp(app) {
                let identity = "\(extra.title ?? "")|\(extra.identifier ?? "")"
                let occurrence = seen[identity, default: 0]
                seen[identity] = occurrence + 1
                if "\(identity)|\(occurrence)" == key { return extra }
            }
            return nil
        }.value
    }

    /// Finds where an item is actually rendered by sweeping
    /// AXUIElementCopyElementAtPosition across the visible bar region and
    /// matching the owning process. AX positions are logical and can drift
    /// tens of pixels after the system rebalances — hit-testing is ground
    /// truth. Runs off the main thread.
    private func renderedCenterX(of item: MenuBarItem) async -> CGFloat? {
        guard let pid = item.appPID else { return nil }
        let boundary = collapseBoundary
        let approx = item.frame
        let screenMax = NSScreen.main?.frame.maxX ?? 1512
        return await Task.detached {
            let sys = AXUIElementCreateSystemWide()
            func hitMatches(_ x: CGFloat) -> Bool {
                var el: AXUIElement?
                guard AXUIElementCopyElementAtPosition(sys, Float(x), 16, &el) == .success,
                      let hit = el
                else { return false }
                var hitPID: pid_t = 0
                AXUIElementGetPid(hit, &hitPID)
                return hitPID == pid
            }
            // Cheap pass first: the item's logical span ± its width.
            var xs = [CGFloat]()
            let lo = max(boundary + 2, approx.minX - approx.width)
            let hi = approx.maxX + approx.width
            var x = lo
            while x <= hi { xs.append(x); x += 4 }
            // Fallback: the whole visible region.
            var wx = boundary + 2
            while wx <= screenMax { xs.append(wx); wx += 4 }
            var hits = [CGFloat]()
            for px in xs where hitMatches(px) { hits.append(px) }
            guard !hits.isEmpty else { return nil }
            // An app may publish several extras — cluster contiguous hits
            // (>8px gap splits) and take the cluster nearest the AX position.
            var clusters = [[CGFloat]]()
            for h in hits {
                if var last = clusters.last, h - last.last! <= 8 {
                    last.append(h); clusters[clusters.count - 1] = last
                } else {
                    clusters.append([h])
                }
            }
            let best = clusters.min(by: {
                abs(($0.first! + $0.last!) / 2 - approx.midX)
                    < abs(($1.first! + $1.last!) / 2 - approx.midX)
            })!
            return (best.first! + best.last!) / 2
        }.value
    }

    /// Re-reads the owning app's extras and polls the item's position
    /// against a predicate — the system's AX position update lags a move
    /// by up to ~1s, so we poll briefly before giving up.
    private func positionCheck(
        _ item: MenuBarItem,
        where predicate: (CGPoint, CGSize) -> Bool
    ) async -> Bool {
        guard let bundleID = item.appBundleID else { return false }
        let key = Self.key(of: item)
        for attempt in 0...7 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let live = await Self.findExtra(bundleID: bundleID, matching: key),
               predicate(live.position, live.size) {
                return true
            }
        }
        return false
    }

    /// Writes AXPosition on an extra. On macOS 27 the setter returns an
    /// error yet still applies — so we ignore the code and verify by
    /// polling the position afterwards.
    private nonisolated static func setAXPosition(_ element: AXUIElement, to point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
        }
    }

    private func isParked(_ p: CGPoint) -> Bool {
        p.x < 0 || p.y < 0 || p.y > 45
    }

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private nonisolated static func axValue(_ vals: [Any], at index: Int) -> AXValue? {
        guard index < vals.count else { return nil }
        let v = vals[index] as CFTypeRef
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
