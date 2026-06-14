# CLAUDE.md — KaJi 协作规则

> 这是用户与 Claude 协作的硬性约束。出现冲突时，本文件优先于默认行为。
> 用户最反感的是「反复纠正同一个问题」——请在每次改动前对照本文件。

---

## 0. 核心工作流（最重要！每次都走四步）

1. **理解** — 把用户要求复述一遍。如果连复述都不清楚，停下来问。
2. **规划** — 在心里过 ≥2 个方案，列出各自代价，选一个。
3. **修改** — 写代码。
4. **验证** — 立刻 build + 看效果 + 自检「符合预期吗？」。**不验证就不算完成**。

**禁止不思考就写代码**。**禁止把验证留给用户**。

同一类 bug 出现第二次就是流程失败。出现第三次必须停下重新读本文件。

## 0.1 硬性底线

- **优先用 macOS 原生组件**：能用 AppKit / SwiftUI 原生控件的，**禁止**自己造。常见场景：
  - 搜索 → `NSSearchField` / `NSSearchToolbarItem`
  - 工具栏 → `NSToolbar` / `NSTitlebarAccessoryViewController`
  - 列表选择 → `NSTableView` / SwiftUI `List`
  - 按钮 → `NSButton` 带系统 bezel
  - 颜色 → `NSColor` 系统语义色
- **禁止引入新 bug**：每次改完先自检 ①已确认的功能没坏 ②新功能自己跑一遍 ③没有死代码/硬编码/凑合的临时方案。确认前不要交付给用户。

## 1. 全局思考（修 bug 时）

- **影响面**：改了某个文件，会不会影响其他视图、布局、交互、状态？
- **方案对比**：至少在心里跑过 ≥2 种思路再动手，列出各自代价。
- **自检**：写完代码后能说出这段代码的预期视觉效果/交互行为吗？和用户最初要求是否一致？
- **回归**：这次改动会破坏之前的哪些已确认功能？traffic-lights、侧栏切换、卡顿优化、tag 截断到 10、统计缓存、窗口大小持久化等都是已确认项，不能破坏。
- **根因 memory**：发现非显而易见的根因，写到 `~/.claude/projects/-Users-xinmin-openmind/memory/`。

## 2. 目标环境

- 硬件：MacBook Pro M1 Pro，16GB + 1TB
- 系统：macOS 26（最新）
- Xcode：最新稳定版
- 部署目标：`macOS 15.0+`（项目当前设置）
- 写任何 macOS 原生代码时，**优先使用最新 API**（macOS 14/15 引入的 `NavigationSplitView` 增强、`@Observable`、原生 `NSToolbar` / `NSTitlebarAccessoryViewController`、`NSSearchField` 等）
- Swift 版本：6.0
- 绝不写向后兼容旧 OS 的兜底代码，除非用户明确要求

## 3. 代码质量

- **禁止死代码**：写完检查，是否有未引用的属性、函数、import、结构体
- **禁止硬编码**：颜色、尺寸、动画时长等都要有命名常量或语义化命名
- **禁止业余写法**：重复的 `.foregroundStyle(.black)`、手写 wrapper、凑合的布局 hack
- **充分利用原生组件**：
  - 搜索 → `NSSearchField` / `NSSearchToolbarItem`
  - 工具栏 → `NSToolbar` / `NSTitlebarAccessoryViewController`
  - 按钮 → `NSButton` 带系统 bezel
  - 颜色 → `NSColor` 系统语义色（`controlColor`、`controlBackgroundColor`、`separatorColor`）
  - 布局 → SwiftUI 用 `NavigationSplitView` / `Grid` / `Table`，AppKit 用 `NSStackView`
- **多 Agent 并行**：用户明确要求过。独立可并行的任务用 workflow 拆 agent 同时跑，避免串行试错

## 4. UI / 交互红线

- **traffic-lights 必须在侧栏内**：`titlebarAppearsTransparent` + `fullSizeContentView` + `NSHostingController` 的组合，**不能**给 `window.toolbarStyle` 赋值（会破坏布局）
- **搜索按钮位置**：右上角，紧贴窗口右边缘，与 traffic-lights 同一水平线
- **搜索展开方向**：从按钮左侧**向左**展开（按钮在右不动，搜索框从右往左生长）
- **点击外部关闭**：NSSearchField 失焦原生处理，**不**用覆盖层、不用 simultaneousGesture
- **悬停效果**：用 `NSColor.controlColor`（系统控件 hover 灰），不要用 `Color(white: 0.88)` 这种硬编码
- **侧栏切换按钮**：必须保留 `NavigationSplitView` 系统自动生成的那一个，不要手动再加

## 5. 已知技术债（持续维护）

- GRDB 接入方式（仓库引用，非 SPM）
- 卡顿：侧栏统计必须用 `AppState.cachedTypeCounts` / `cachedTagCounts`，禁止每次渲染读库
- 标签 Top 10：`Array(appState.tagCounts().prefix(10))`
- 窗口大小：`setFrameAutosaveName("KaJiMainWindow")` + 按屏幕比例计算

## 6. 利用 MCP 和技能

- 文档查询 → `mcp__context7__`（SwiftUI / AppKit / GRDB）
- 通用搜索 → `WebSearch` / `WebFetch`
- 多 Agent 并行 → `Workflow` 工具
- 写代码前先想：能不能用某个已配置的 skill / MCP 一次到位？
