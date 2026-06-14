# 2026-06-14 方案对比：traffic-lights / 侧栏切换按钮 + 1 万卡搜索性能

> 用户核心约束：Mac M1 Pro / macOS 26 / Xcode 最新 / 颜值即正义 / 启动速度不能受影响。
> 本文件记录两个关键决策点的方案对比。

---

## 决策 1：traffic-lights 与侧栏切换按钮都在侧栏内

### 根因
当前窗口配置：

```swift
styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
titlebarAppearsTransparent = true
titleVisibility = .hidden
contentViewController = NSHostingController(rootView: MainView())
```

- `fullSizeContentView` 让 content view 延伸到 titlebar 区域
- `titlebarAppearsTransparent` 让 titlebar 区域透明
- SwiftUI `NavigationSplitView` 侧栏背景顶到 `(0,0)`
- → 系统 traffic-lights 视觉上浮在侧栏左上角圆角矩形内
- → `NavigationSplitView` 自带的「切换侧栏」按钮也落在侧栏顶部

### 方案对比

| 方案 | 做法 | 利 | 弊 | 启动影响 |
|---|---|---|---|---|
| **A. 当前** | 透明 titlebar + `NSHostingController` + 侧栏 List 顶到 (0,0) | 视觉最干净，圆点 / 侧栏切换按钮天然落在侧栏内；与 macOS Finder / 设置完全一致 | 标准 `NSToolbar` / `NSTitlebarAccessory` 方案会冲突，需要用 SwiftUI 浮层绕过 | **~0 ms**（NSHostingController 桥接一次性） |
| B. 标准 `WindowGroup` + 标准 titlebar | 退到 SwiftUI 默认窗口 | `NSToolbar` / `.searchable` 全部能直接用 | 圆点 / 侧栏切换按钮 **不再** 浮在侧栏内（变标准 toolbar 布局） | 略快（少一个 NSHostingController） |
| C. `NSToolbar` 不设 `toolbarStyle` | 透明 titlebar + 系统 toolbar | 系统原生 toolbar 体验 | 圆点可能被 toolbar 推开；toolbar item 内部尺寸不能动态调整（accessory view 只能装固定 32×32） | 略慢（NSToolbar 启动时初始化） |
| D. 自定义 chrome 顶栏 | 退掉 `styleMask: .titled`，自己画顶栏 | 100% 自定义 | 失去原生 traffic-lights 行为（拖动、zoom、原生红绿灯） | 略慢（多一层渲染） |
| E. 接受圆点被推开 | 装 `NSToolbar` 不动窗口结构 | 最简单 | **违背核心视觉要求** | ~0 |

### 推荐：**A**

理由：
1. 启动影响最小（NSHostingController 桥接 < 50ms，发生在首次窗口创建）
2. 视觉与 macOS 原生应用（Finder / 系统设置）一致
3. 唯一代价是 NSToolbar 方案不可用 → 用 SwiftUI 浮层绕开，性能影响可忽略

### 后续约束
- 永远不要给 `window.toolbarStyle` 赋值
- 永远不要装 `NSToolbar`
- 任何需要挂在 titlebar 的组件（如搜索）都用 SwiftUI 浮层 + `NSEvent` 全局点击监听

---

## 决策 2：1 万张卡片下的搜索性能

### 当前数据流

```
SwiftUI 浮层 SearchOverlay
  → TextField 输入
  → @Published AppState.searchKeyword 变化
  → 触发 DetailView 重新渲染
  → SearchResultsView 重新执行：
      let results = appState.search(appState.searchKeyword)
      → AppState.search() → CardRepository.search(keyword: kw)
        → GRDB SQL LIKE '%kw%' 全表扫描
```

### 性能基线（1 万张卡片，每张 ~20 字符标题+若干字段）

| 步骤 | 时间 | 说明 |
|---|---|---|
| SwiftUI 状态变化触发重绘 | 几 ms | UI 必须重绘 |
| GRDB SQL LIKE 全表扫描 | **100–300 ms** | 单次 |
| SearchResultsView 渲染 | 10–50 ms | 取决于结果数 |
| 每次按键都重新查 | 累计 = 100ms × N | **N=20 时键入 20 字符** |

### 方案对比

| 方案 | 1 万卡延迟 | 改动量 | 用户体验 |
|---|---|---|---|
| **A. 当前（实时 SQL LIKE）** | 100–300 ms / 键 | 0 | 每次按键都查，1 万卡顿感明显 |
| **B. 加 300ms debounce** | 100–300 ms / 300ms | 5 分钟 | 输入流畅，停顿后看到结果 |
| **C. 加 debounce + FTS5 全文索引** | 5–20 ms / 查 | 1–2 小时 | 极流畅，1 万/10 万卡无感 |

### 性能优化空间（详细）

#### B. Debounce

```swift
// 在 AppState 里加 Combine debounce
$searchKeyword
    .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
    .sink { [weak self] keyword in
        self?.search(keyword)
    }
    .store(in: &cancellables)
```

注意：`searchKeyword` 仍需实时绑定到 UI（让 TextField 显示输入），但**查询操作**用 debounce 后的值。

#### C. FTS5 全文索引

```swift
// 1. 创建 FTS5 虚拟表（一次性）
CREATE VIRTUAL TABLE card_fts USING fts5(
    id UNINDEXED,
    title,
    content,
    tokenize = 'unicode61'
);

// 2. 插入 / 更新 / 删除时同步 card_fts

// 3. 查询走 MATCH 操作符
SELECT c.* FROM cards c
JOIN card_fts ON card_fts.id = c.id
WHERE card_fts MATCH ?
ORDER BY rank
LIMIT 50;
```

GRDB 提供 `db.create(virtualTable:options:body:)` API 一行创建。

### 推荐：**先 B，后 C**

- B：5 分钟解决主观卡顿
- C：1–2 小时，长期最优（10 万/100 万卡也流畅）

---

## 总结

| 决策 | 选择 | 原因 |
|---|---|---|
| 窗口结构 | A 透明 titlebar + NSHostingController | 视觉优先，启动影响几乎为零 |
| 搜索性能 | B（先）+ C（后） | 5 分钟改 debounce，1–2 小时加 FTS5 |
