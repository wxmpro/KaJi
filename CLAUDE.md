# CLAUDE.md — KaJi 协作规则

> 这是用户与 Claude 协作的硬性约束。出现冲突时，本文件优先于默认行为。
> 用户最反感的是「反复纠正同一个问题」——请在每次改动前对照本文件。

---

## 0. 核心工作流（最重要！每次都走四步）

1. **理解** — 把用户要求复述一遍。如果连复述都不清楚，停下来问。
2. **规划** — 作为资深软件架构师和编程极客，以长期视角，不计成本和时间，提高软件运行的质量和速度。
3. **修改** — 写代码。
4. **验证** — 立刻 build + 看效果 + 自检「符合预期吗？」。**不验证就不算完成**。

**禁止不思考就写代码**。**禁止把验证留给用户**。

同一类 bug 出现第二次就是流程失败。出现第三次必须停下重新读本文件。

## 0.1 硬性底线

- **优先用 macOS 26 原生组件**
- **禁止引入新 bug**：每次改完先自检 ①已确认的功能没坏 ②新功能自己跑一遍 ③没有死代码/硬编码/凑合的临时方案。确认前不要交付给用户。

## 0.2 GitHub 推送与版本号铁律

**原则：每一次推送到 GitHub 都必须是一个带版本号的正式版本。没有版本号的推送不允许发生。**

### 版本号格式

采用语义化版本 `MAJOR.MINOR.PATCH`：

- **MAJOR**：不兼容的破坏性变更、用户数据格式变更、核心交互范式改变
- **MINOR**：新功能、架构重构、较大的模块拆分、影响面较广的内部改造
- **PATCH**：bugfix、小优化、UI 微调、文案调整

### 每次推送前必须完成以下四步

1. **更新版本号**
   - 修改 `KaJi.xcodeproj/project.pbxproj`：
     - `MARKETING_VERSION` → 新的 `MAJOR.MINOR.PATCH`
     - `CURRENT_PROJECT_VERSION` → build 号递增
   - 这是硬性要求，**禁止**在版本号未更新的情况下推送。

2. **写清楚 commit message**
   - 第一行必须是：`release: KaJi vX.Y.Z`
   - 正文必须列出本次版本更新的核心内容，包含：
     - 版本号变化
     - 主要改动分类
     - 验证结果（build 是否通过）

3. **创建 git tag**
   - 必须打 tag：`git tag vX.Y.Z`
   - **禁止覆盖已有 tag**。如果 `vX.Y.Z` 已存在，必须递增版本号，不能强制推送 tag。

4. **验证通过**
   - 推送前必须执行完整 build：
     ```bash
     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodebuild -project KaJi.xcodeproj -scheme KaJi -destination 'platform=macOS' build
     ```
   - **BUILD FAILED 时禁止推送**。

### 推送命令

```bash
git add .
git commit -F /tmp/release_vX.Y.Z_msg.txt   # 使用写好的 release message
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

### 禁止事项

- **禁止无版本号推送**
- **禁止 build 失败时推送**
- **禁止覆盖已有 tag**
- **禁止同一版本号重复推送不同 commit**
- **禁止只推送代码不推送 tag**

### 版本号决策示例

| 改动类型 | 正确版本号变化 | 示例 |
|----------|----------------|------|
| 修复一个 UI bug | PATCH 递增 | `1.2.0` → `1.2.1` |
| 新增一个设置项 | MINOR 递增 | `1.2.1` → `1.3.0` |
| 重构 AppState 拆分 | MINOR 递增 | `1.1.2` → `1.2.0` |
| 用户数据格式不兼容升级 | MAJOR 递增 | `1.x.x` → `2.0.0` |

> 用户最严厉的约束：**推送一次就是一个版本号。版本号不是装饰，是每次交付的必备身份。**

## 1. 全局思考（修 bug 时）

- **影响面**：改了某个文件，会不会影响其他视图、布局、交互、状态？
- **方案**：利用元反空skill深度思考出现的bug，输出最极致、最优雅的解决方案。
- **自检**：写完代码后能说出这段代码的预期视觉效果/交互行为吗？和用户最初要求是否一致？
- **回归**：这次改动会破坏之前的哪些已确认功能？traffic-lights、侧栏切换、卡顿优化、tag 截断到 10、统计缓存、窗口大小持久化等都是已确认项，不能破坏。
- **根因 memory**：发现非显而易见的根因，写到 本项目的 memory。

## 2. 目标环境

- 硬件：MacBook Pro M1 Pro，16GB + 1TB
- 系统：macOS 26（最新）
- Xcode：最新稳定版
- 部署目标：`macOS 15.0+`（项目当前设置）
- 写任何 macOS 原生代码时，**坚定优先使用最新 API**
- Swift 版本：6.0
- 绝不写向后兼容旧 OS 的兜底代码，除非用户明确要求

## 3. 代码质量

- **禁止死代码**：写完检查，是否有未引用的属性、函数、import、结构体
- **禁止硬编码**：颜色、尺寸、动画时长等都要有命名常量或语义化命名
- **禁止业余写法**：重复的 `.foregroundStyle(.black)`、手写 wrapper、凑合的布局 hack
- **充分利用 Mac OS 26各种原生组件**
- **多 Agent 并行**：用户明确要求过。独立可并行的任务用 workflow 拆 agent 同时跑，避免串行试错

## 4. UI / 交互红线

- **traffic-lights 必须在侧栏内**
- **搜索按钮位置**：右上角，紧贴窗口右边缘，与 traffic-lights 同一水平线
- **搜索展开方向**：从按钮左侧**向左**展开（按钮在右不动，搜索框从右往左生长）
- **点击外部关闭**：NSSearchField 失焦原生处理，**不**用覆盖层、不用 simultaneousGesture
- **两种模式**：视觉效果，外观，颜色，动效必须统一
- **侧栏切换按钮**：必须保留 `NavigationSplitView` 系统自动生成的那一个，不要手动再加



## 7. 利用 MCP 和技能

- 文档查询 → `mcp__context7__`（SwiftUI / AppKit / GRDB）
- 通用搜索 → `WebSearch` / `WebFetch`
- 多 Agent 并行 → `Workflow` 工具
- 写代码前先想：能不能用某个已配置的 skill / MCP 一次到位？
