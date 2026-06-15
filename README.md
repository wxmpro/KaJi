# 卡迹 KaJi

> macOS 原生卡片笔记应用。

![platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue)
![swift](https://img.shields.io/badge/swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

## 简介

卡迹（KaJi）是一款为 macOS 设计的原生卡片笔记工具，采用 SwiftUI + AppKit 构建，使用 Swift 6 并发模型。它以"卡片"为最小单位，帮助用户快速记录术语、反常识、新知、人物、金句、行动等多种类型的知识片段。

## 功能特性

- **11 种内置卡片类型**：术语卡、反常识卡、新知卡、人物卡、金句卡、新词卡、行动卡、事件卡、图示卡、索引卡、综述卡、自由卡
- **原生 macOS 窗口设计**：traffic-lights 融入侧栏、透明 titlebar、按屏幕比例计算默认窗口尺寸
- **两栏布局**：左侧导航侧栏，右侧根据状态切换编辑器或卡片列表
- **搜索**：右上角搜索入口，结果以列表形式呈现
- **标签系统**：每张卡片可打标签，侧栏展示常用标签 Top 10
- **回收站**：软删除卡片，支持恢复，超过保留天数后自动清理
- **设置面板**：主题、自动保存间隔、回收站保留天数、数据位置、版本信息

## 系统要求

- macOS 15.0+
- Xcode 最新稳定版（用于开发构建）
- Swift 6.0

## 构建与运行

```bash
# 克隆仓库
git clone https://github.com/wxmpro/KaJi-macOS.git
cd KaJi-macOS

# 用 Xcode 打开项目
open KaJi.xcodeproj

# 或在命令行构建 Debug 版本
xcodebuild -project KaJi.xcodeproj -scheme KaJi -destination 'platform=macOS' build

# 构建 Release 版本
xcodebuild -project KaJi.xcodeproj -scheme KaJi -configuration Release -destination 'platform=macOS' build
```

## 项目结构

```
KaJi/
├── App/                    # 应用入口与全局状态
│   ├── KaJiApp.swift       # App 生命周期、窗口创建、菜单命令
│   ├── EditorState.swift   # 当前卡片、编辑、搜索、自动保存
│   ├── ListState.swift     # 列表筛选、右栏模式
│   └── StatsState.swift    # 统计缓存、全量卡片缓存
├── Database/               # GRDB.swift 数据层
│   ├── AppDatabase.swift
│   ├── CardRepository.swift
│   ├── CardRecord.swift
│   └── CardFileIO.swift
├── Models/                 # 数据模型
│   ├── Card.swift
│   ├── CardField.swift
│   ├── CardType.swift
│   └── ListFilter.swift
├── Services/               # 业务服务
│   ├── CardService.swift
│   ├── CardLifecycleService.swift
│   ├── CardTypeChangeService.swift
│   └── PersistenceCoordinator.swift
├── Utilities/              # 工具类
│   ├── SettingsService.swift
│   ├── ExportService.swift
│   ├── CardIDGenerator.swift
│   ├── ContentLimit.swift
│   └── KaJiLayout.swift
└── Views/                  # SwiftUI 视图
    ├── Main/
    ├── Sidebar/
    ├── List/
    ├── Editor/
    ├── Search/
    ├── Settings/
    └── Components/
```

## 版本历史

| 版本 | 说明 |
|------|------|
| v1.2.2 | 重构设置窗口（通用/高级/关于三标签），新增自动保存间隔、回收站保留天数设置 |
| v1.2.1 | 在 `CLAUDE.md` 中明确 GitHub 推送与版本号管理规则 |
| v1.2.0 | 架构重构：拆分 `AppState` 为 `EditorState` / `ListState` / `StatsState` |
| v1.1.2 | 表单化编辑器、卡片类型切换保护、标签 / UUID 底部栏 |
| v1.1.1 | 主题 / 侧栏 / 横线 / 搜索 UI 调整 |
| v1.1.0 | 两栏浏览模式、导航历史、统一按钮 hover、设置窗口 |
| v1.0.0 | 初始版本：macOS 原生两栏卡片笔记 |

## 应用体积

- Debug 构建：约 9.3 MB（含调试符号和预览动态库）
- Release 构建：约 6.1 MB

## 数据存储

- 卡片数据以 `.md` 文件形式保存在 `~/Library/Application Support/KaJi/` 目录
- 元数据和索引保存在同目录下的 SQLite 数据库中
- 数据位置可在「设置 → 高级」中查看并打开

## 开发规范

详见项目根目录下的 [`CLAUDE.md`](CLAUDE.md)，包含：

- 核心工作流（理解 → 规划 → 修改 → 验证）
- GitHub 推送与版本号铁律
- UI / 交互红线
- 代码质量要求

## 版权

© 2026 KaJi. All rights reserved.
