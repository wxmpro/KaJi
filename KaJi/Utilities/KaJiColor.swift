//
//  KaJiColor.swift
//  KaJi
//
//  统一色板常量。所有常量按 SemanticColor（浅深模式双值），调用方 `.resolve(for: colorScheme)`。
//
//  设计原则：
//  - 命名按"角色"而非"颜色值"（cardShadow / listRowHover）
//  - 浅深模式由 SemanticColor 自动解析
//  - 系统语义色（accentColor / separatorColor）保留直接 Color 类型
//

import SwiftUI

enum KaJiColor {
    // MARK: - 卡片
    static let cardShadow      = SemanticColor(light: .gray.opacity(0.30),  dark: .white.opacity(0.08))
    static let cardShadowHover = SemanticColor(light: .gray.opacity(0.12),  dark: .black.opacity(0.35))   // picker 浮层 hover 阴影
    static let cardBorder      = SemanticColor(light: .gray.opacity(0.35),  dark: .white.opacity(0.15))
    static let cardBackground  = SemanticColor(light: .white,               dark: Color(nsColor: .textBackgroundColor))
    static let cardFieldStroke = SemanticColor(light: .black,               dark: .white.opacity(0.55))

    // MARK: - 列表行 / 侧栏行
    static let listRowHover      = SemanticColor(light: .gray.opacity(0.20), dark: .white.opacity(0.10))
    static let listRowSelected   = SemanticColor(light: .gray.opacity(0.30), dark: .white.opacity(0.12))
    static let listRowPressed    = SemanticColor(light: .gray.opacity(0.45), dark: .white.opacity(0.22))
    static let sidebarRowHover   = SemanticColor(light: .gray.opacity(0.20), dark: .white.opacity(0.10))
    static let sidebarRowPressed = SemanticColor(light: .gray.opacity(0.35), dark: .white.opacity(0.15))

    // MARK: - 分割线 / 系统语义色
    static let separator      = SemanticColor(light: .gray.opacity(0.25),    dark: .white.opacity(0.10))
    static let systemAccent   = Color(nsColor: .controlAccentColor)
    static let systemSeparator = Color(nsColor: .separatorColor)
    static let systemControl  = Color(nsColor: .controlColor)
    static let systemSelected = Color(nsColor: .selectedControlColor)

    // MARK: - 侧栏
    /// sidebar 整体背景色；NavigationSplitView 的 sidebar 列用它填到 titlebar 顶部
    /// 系统色 .windowBackgroundColor 自动跟随浅深模式，与系统窗口同源
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
}