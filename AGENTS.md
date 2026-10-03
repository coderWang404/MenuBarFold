# MenuBarFold — macOS 顶栏折叠管理工具

MacBook 刘海会遮挡菜单栏图标。本工具在菜单栏放一个 chevron 图标，点击弹出下拉面板：
可逐项折叠/展开顶栏图标；点击已折叠项会把它临时移回菜单栏、模拟点击弹出菜单，15s 后自动收回。

## 构建与运行

```bash
bash build.sh                     # swift build -c release + 打包 build/MenuBarFold.app + ad-hoc 签名
open build/MenuBarFold.app        # 运行（无 Dock 图标，LSUIElement）
```

无 Xcode 依赖，只需 Command Line Tools。调试输出走 stderr（直接跑二进制可见）。

## 调试钩子（DistributedNotificationCenter）

```bash
/tmp/post_notif foldFirst    # 折叠"顶栏项"列表第一项（spike/post_notif.swift 可重建）
/tmp/post_notif unfoldFirst  # 展开折叠区第一项
/tmp/post_notif unfoldMatch "id:<needle>"  # 展开 stableID 包含 needle 的折叠项（当前实现读 userInfo["id"]）
/tmp/post_notif useFirst     # 临时移回+点击折叠区第一项
/tmp/post_notif togglePanel  # 开关下拉面板
```

`spike/` 目录是独立验证工具：`enum_test`（枚举菜单栏窗口）、`ax_apps_test`（各 App 的
AXExtrasMenuBar）、`move_test`（合成 ⌘-drag 移动）、`click_test`（合成点击）。

## 核心机制（参考开源项目 Ice，代码自写）

- **枚举（两层，性能关键）**：
  - *几何层*（主线程，每 5s/开面板，~20ms）：`CGSGetProcessMenuBarWindowList` +
    `CGWindowListCopyWindowInfo(.optionAll)` + `CGSGetScreenRectForWindow` → 窗口 ID/位置/分区。
    ⚠️ `.optionIncludingWindow` 对**离屏**窗口返回空，不能用来逐窗口查询。
  - *身份层*（后台线程，按需+60s 定时）：逐 App `AXExtrasMenuBar`（约 120 个 App 的同步 AX IPC，
    主线程跑会卡 UI 数秒）。加 `AXUIElementSetMessagingTimeout(0.5s)` 防个别 App 不响应，
    `AXUIElementCopyMultipleAttributeValues` 批量取属性。结果按 windowID 缓存，
    只在**新 windowID 出现**时才触发（sawNewWindow），避免无法匹配项导致无限重试。
  - *匹配*：窗口 frame ∩ AX 位置 ±3px → 兜底：±45px 最近位置配对（AX 位置会漂移；
    千万别放宽到 ~90px——图标间距仅 32-40px，会把相邻项标错名，出现"点 A 开 B"）。
    `_AXUIElementGetWindow`（Ice 的精确匹配法）在 macOS 26 已失效（全返回 -25201）。
    折叠项的 AX 位置**实时跟踪**窗口位置，无需特殊处理。排除 own extras 与
    isParkedPosition（y<0 / (0,982)）哨兵项。
- **启动规范化+修复**：分隔符槽位在重启间会漂移 → 物理折叠集≠持久化集。`restoreFolds`
  先按 foldedIDs 折回 → 不在 foldedIDs 的物理折叠项全部展开 → **修复：onscreen 且
  minX < boundary-20 的项（压在应用菜单上）移回可见簇**，保证折叠集=用户选择且
  可见区无错位项。⚠️ 必须先等身份合并完成（stableID 含 bundleID）。
- **展开落点**：`visibleDropDestination()` = 可见簇最左项 leftOf（x≥boundary）。
  ⚠️ 不要用"分隔符 rightOf"——那里 x≈0-250 是应用菜单区，图标会画在菜单上。
  `use()` 调用前必须 `refresh()` + 按 stableID 重新解析行对象（wid 会被重建）。
- **隐藏**：分隔符 `NSStatusItem.length = 屏幕宽`，把左侧有序的项挤出屏幕（窗口仍存活）。
  分区判定：`item.frame.maxX <= divider.frame.minX` → 折叠区。
- **移动**：合成 ⌘-drag `CGEvent`，关键是用私有字段直接指定目标窗口——
  `.mouseEventWindowUnderMousePointer`、`.windowID`(0x33)、`.eventTargetUnixProcessID`，
  因此鼠标坐标可在屏幕外（grab 点 20000,20000），被隐藏项也能拖动。post 到 `.cgSessionEventTap`。
- **使用折叠项**：移到可见区最左侧有空位项的左边（boundary = `auxiliaryTopRightArea.minX`，
  即刘海右缘）→ 点击 → 定时器到点拖回分隔符左侧。
- **持久化**：`foldedIDs`（`bundleID|axTitle|windowTitle`）存 UserDefaults，启动恢复。
- **不可移动项**：Clock / Siri / BentoBox（控制中心自身）等黑名单；`AudioVideoModule`、
  `FaceTime`、`MusicRecognition` 不可折叠。

## 已知限制

- 被系统彻底移除的项（AX 位置 y=-1，无窗口）显示为"已移除"灰色行，需重启对应 App 恢复。
- Ad-hoc 签名：重编译后 cdhash 变化，辅助功能授权可能要重新勾选。
- 多屏/多 Space 未处理；折叠顺序在重启后按持久化集合恢复（精确位置不保证）。
- macOS 私有 API，系统升级有失效风险。

## 文件结构

```
Sources/MenuBarFold/
  main.swift               入口（NSApplication + AppDelegate，.accessory）
  AppDelegate.swift        启动编排 + 辅助功能权限引导
  AppState.swift           全局状态
  Bridging.swift           私有 CGS API（@_silgen_name）
  WindowInfo.swift         CGWindowList 包装
  MenuBarItem.swift        项模型 + 黑名单 + displayName
  MenuBarItemManager.swift 枚举/分区/折叠/展开/tempShow/自动收回/持久化 + 调试钩子
  EventPoster.swift        窗口定向合成事件（move/click）
  ControlItems.swift       chevron + 分隔符 NSStatusItem
  PanelController.swift    NSPanel 锚定 chevron 下方
  PanelView.swift          SwiftUI 下拉列表
  SettingsStore.swift      UserDefaults
  Log.swift                stderr 日志
```
