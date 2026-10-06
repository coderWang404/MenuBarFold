import SwiftUI

struct PanelView: View {
    @ObservedObject var manager: MenuBarItemManager
    let controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    foldedSection
                    otherSection
                    parkedSection
                }
                .padding(6)
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack {
            Text("顶栏折叠")
                .font(.headline)
            Spacer()
            if !manager.isTrusted {
                Text("需要辅助功能权限")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("\(manager.collapsedItems.count) 项已折叠")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var foldedSection: some View {
        if !manager.collapsedItems.isEmpty {
            Text("已折叠 — 点击使用（展开请拖出系统 ⌄ 区）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(manager.collapsedItems) { item in
                ItemRow(item: item, actionTitle: "展开") {
                    Task { await manager.unfold(item) }
                } onUse: {
                    controller.close()
                    Task { await manager.use(item) }
                }
            }
        }
    }

    @ViewBuilder
    private var otherSection: some View {
        if !manager.visibleItems.isEmpty {
            Text("顶栏项")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(manager.visibleItems) { item in
                ItemRow(
                    item: item,
                    actionTitle: item.canBeHidden ? "折叠" : nil
                ) {
                    Task { await manager.fold(item) }
                } onUse: {
                    controller.close()
                    Task { await manager.use(item) }
                }
            }
        }
    }

    @ViewBuilder
    private var parkedSection: some View {
        if !manager.parkedItems.isEmpty {
            Text("已被系统移除（重启对应 App 可恢复）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(manager.parkedItems) { item in
                ItemRow(item: item, badge: "已移除", actionTitle: nil, dimmed: true) {
                } onUse: {
                    controller.close()
                    Task { await manager.use(item) }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = manager.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("⌃⌥M 开关面板")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ItemRow: View {
    let item: MenuBarItem
    var badge: String? = nil
    var actionTitle: String?
    var dimmed: Bool = false
    let onAction: () -> Void
    let onUse: () -> Void

    // @State is a compiler macro in the macOS 27 SDK and its plugin isn't
    // shipped with Command Line Tools — expand the property-wrapper storage
    // manually (identical desugaring: `_x` storage + computed accessor).
    private var _isHovering = State(initialValue: false)
    private var isHovering: Bool {
        get { _isHovering.wrappedValue }
        nonmutating set { _isHovering.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(item.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.2), in: Capsule())
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering && !dimmed ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onTapGesture(perform: onUse)
    }

    @ViewBuilder
    private var icon: some View {
        if let icon = item.appIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "menubar.rectangle")
                .frame(width: 18, height: 18)
        }
    }
}

/// AppKit-backed material background for SwiftUI.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
