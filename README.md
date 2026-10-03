# MenuBarFold

macOS 菜单栏（顶栏）折叠管理工具 —— 在刘海屏 MacBook 上把塞不下的菜单栏图标收进下拉面板。

类似 Bartender / Hidden Bar / Ice 的核心能力，Swift + AppKit 实现，无依赖。

## 功能

- 菜单栏放一个 chevron 图标，点击弹出下拉面板
- 逐项折叠 / 展开菜单栏图标
- 点击已折叠项：临时移回菜单栏 → 模拟点击弹出它的菜单 → 15 秒后自动收回
- 折叠状态持久化（重启 App 自动恢复）
- 被系统移除的项单独标注，可尝试 AXPress 兜底激活

## 构建与运行

只需要 Command Line Tools（不需要 Xcode）：

```bash
bash build.sh                  # 编译 + 打包 build/MenuBarFold.app + ad-hoc 签名
open build/MenuBarFold.app     # 运行（无 Dock 图标）
```

需要**辅助功能权限**——系统会弹窗引导授权。ad-hoc 签名每次重编译 cdhash 会变，可能需要重新勾选权限。

## 工作原理

macOS 没有公开 API 隐藏菜单栏项。本工具采用与开源项目 Ice 相同的机制（代码自写）：

- **枚举**：私有 `CGSGetProcessMenuBarWindowList` 拿到所有菜单栏项窗口。
  macOS 26 上 extras 窗口统一由 ControlCenter 托管，真实归属通过对每个 App 的
  `AXExtrasMenuBar` 做位置匹配解析。
- **隐藏**：一个不可见的分隔符 `NSStatusItem` 展开到屏幕宽度，把它左侧的项全部
  挤出屏幕（窗口存活，只是画不到）。折叠区 = `item.frame.maxX <= divider.frame.minX`。
- **移动**：合成 ⌘-drag `CGEvent`，通过私有事件字段指定目标窗口
  （`mouseEventWindowUnderMousePointer`、windowID 字段 `0x33`、目标进程 PID），
  因此鼠标坐标可以在屏幕外——被隐藏的项也能拖动。
- **性能**：枚举分两层——几何层（CGS，~20ms，主线程高频跑）+ 身份层（逐 App AX IPC，
  后台线程低频跑，按 windowID 缓存 + 锚点约束对齐配对）。

## 已知限制

- 使用私有 API（CGS/合成事件定向字段），系统升级有失效风险。已在 macOS 26 (arm64) 实测。
- `_AXUIElementGetWindow` 在 macOS 26 失效，项→App 的身份匹配是位置启发式。
- 多屏 / 多 Space 未处理。
- 项的"已移除"状态（无窗口）需要重启对应 App 才能恢复。

## License

MIT
