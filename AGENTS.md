# MenuBarFold — macOS 顶栏折叠管理工具

MacBook 刘海会遮挡菜单栏图标。本工具在菜单栏放一个 chevron 图标，点击弹出下拉面板：
可逐项折叠/展开顶栏图标；点击任意项通过 AXPress 直接触发其菜单。

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
/tmp/post_notif unfoldMatch "qq"   # 展开 stableID/displayName 包含 needle 的折叠项
/tmp/post_notif useFirst     # AXPress 折叠区第一项
/tmp/post_notif togglePanel  # 开关下拉面板（快捷键 ⌃⌥M 等价）
```

## 核心机制（macOS 27 版 —— 纯 AX，无窗口枚举）

**macOS 27 架构剧变**：`MenuBarAgent` 进程自己合成所有菜单栏项。
`CGSGetProcessMenuBarWindowList` 已失效（所有进程都只返回 Menubar 主窗口），
项不再有独立窗口，`windowID` 定向事件和"分隔符挤出屏幕"整套机制全部作废。

- **枚举 = 逐 App `AXExtrasMenuBar`**（后台线程，约 120 个 App 的同步 AX IPC，
  8s 定时 + 开面板触发，主线程不阻塞）。每个 extra 自带真实归属
  （appPID/bundleID/名称/图标）——**身份是权威的，不是位置猜出来的**。
- **分类**：MenuBarAgent 自己的 `AXButton` extra（"显示隐藏菜单栏项目"，
  约 x=890）是系统折叠边界 `collapseBoundary`：
  - `x ≥ boundary` → 可见（顶栏项）
  - `x < boundary 且 y∈[0,45]` → 已折叠（系统溢出区，可能渲染但不可命中）
  - `x<0 / y<0 / y>45 / (7,986.5)` → 已移除（哨兵位，系统彻底收纳）
- **点击使用 = `AXPress`**：对可见、折叠、哨兵位项都有效——App 照样弹菜单。
  无需"临时移回再收回"那一套。
- **折叠 = `AXUIElementSetAttributeValue(AXPosition)`** ⚠️关键发现：
  写 AXPosition 返回错误码 **但位置真实生效**（写边界内 ~boundary-30 即可折入）。
  兜底：坐标 ⌘-drag（必须先 `AXUIElementCopyElementAtPosition` 扫出**渲染**位置——
  AX 位置是逻辑的，系统重排后可偏离 ~60px，按 AX 中点抓会抓到隔壁项！）。
- **展开 = 同样 AX 写位置**（写到 boundary+60, y=4.5，系统会吸附到合法槽位）。
  折叠区项不可命中（hit-test -25208），坐标拖拽对其无效；AX 写位置是目前唯一
  可靠路径。
- **验证 = 轮询**：移动后 AX 位置更新有延迟，positionCheck 按 250ms×8 轮询。
- **自己的 chevron**：macOS 27 下**新建 NSStatusItem 一律进哨兵位**（写
  autosaveName + Preferred Position 偏好、isVisible 开关、换 bundleID、
  带 menu/纯文本变体、in-process 重建——全部无效）。这是系统级行为：
  同病症见 Stats #3120 / CodexBar #3377 / oMLX #1497 —— 系统设置›菜单栏›
  「允许在菜单栏显示」里的开关只控制 isAllowed，**不强制重新放置**。
  - `x-apple.systempreferences:com.apple.ControlCenter-Settings.extension`
    直达该面板（开关可在 AX 树里找到：名字是静态文本，checkbox 同 y 坐标
    配对）。
  - **实测唯一生效过的恢复：`killall ControlCenter && killall MenuBarAgent`**
    （launchd 自动拉起，菜单栏闪一下）——成功率约 1/5，且重启 agents 会
    重排整个菜单栏布局，**可能把别的 App 的活项打进哨兵位**（观测到
    CC Switch/Qoder CN 被误伤）。所以只有面板里『重试修复』手动触发，
    不做启动自动恢复。最可靠的恢复是重启 Mac（启动时系统重算布局）。
  - 面板入口 = **⌃⌥M** + 哨兵位 chevron 仍响应 AXPress。
  - ⚠️ 别给 chevron 设 `.terminationOnRemoval`：系统收纳时会直接销毁项，
    之后任何手段都救不回来（已去掉）。
- **持久化**：foldedIDs = `bundleID|axTitle|axIdentifier|#occurrence`，
  启动后对仍可见的持久化项重放折叠。

## 已知限制

- "展开"依赖 AX 写位置；若未来系统收紧该属性，折叠区项将无法自动展开
  （坐标拖拽对堆叠项无效——已在 hit-test / 菜单开启态 / 宿主窗口定向三种路径验证）。
- 系统 ⌄ 按钮（MenuBarAgent AXButton）不响应任何合成点击/AX 动作——系统托盘
  展开只能用户手动。
- Ad-hoc 签名：重编译后 cdhash 变化，辅助功能授权可能要重新勾选。
- macOS 27 SDK 把 `@State` 改成了宏，CLT 不带 SwiftUIMacros 插件——
  PanelView 里的悬停态是手动展开的 `State(initialValue:)` 存储写法。

## 文件结构

```
Sources/MenuBarFold/
  main.swift               入口（NSApplication + AppDelegate，.accessory）
  AppDelegate.swift        启动编排 + 权限引导 + ⌃⌥M 全局热键
  AppState.swift           全局状态
  Bridging.swift           私有 CGS API（macOS 27 已失效，保留备查）
  WindowInfo.swift         CGWindowList 包装（同上）
  MenuBarItem.swift        项模型 + placement 分类 + stableID
  MenuBarItemManager.swift AX 枚举/分类/折叠/展开/AXPress/持久化 + 调试钩子
  EventPoster.swift        坐标 ⌘-drag（折叠兜底）
  ControlItems.swift       chevron NSStatusItem（哨兵位感知，无 behavior flags）
  PanelController.swift    NSPanel 锚定（AX 位置优先，右侧兜底）
  PanelView.swift          SwiftUI 下拉列表（三区：已折叠/顶栏项/已移除）
  SettingsStore.swift      UserDefaults
  Log.swift                stderr 日志
```
