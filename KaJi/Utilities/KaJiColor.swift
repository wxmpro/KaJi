//
//  KaJiColor.swift
//  KaJi
//
//  v1.3.0 引入：统一色板常量，替换散落的硬编码颜色。
//
//  设计原则：
//  - 命名按"角色"而非"颜色值"（cardShadowLight / listRowHoverLight）
//  - Light / Dark 双色并列，view 通过 @Environment(\.colorScheme) 选择
//  - 系统语义色（accentColor / separatorColor）保留，由 NSColor 系统解析
//

import SwiftUI

enum KaJiColor {
    // MARK: - 卡片背景与边框
    static let cardShadowLight = Color.gray.opacity(0.30)
    static let cardShadowDark = Color.white.opacity(0.08)
    static let cardBorderLight = Color.gray.opacity(0.35)
    static let cardBorderDark = Color.white.opacity(0.15)
    static let cardBackgroundLight = Color.white
    static let cardBackgroundDark = Color(nsColor: .textBackgroundColor)
    static let cardFieldStrokeLight = Color.black
    static let cardFieldStrokeDark = Color.white.opacity(0.55)

    // MARK: - 列表行
    static let listRowHoverLight = Color.gray.opacity(0.20)
    static let listRowHoverDark = Color.white.opacity(0.10)
    static let listRowSelectedLight = Color.accentColor.opacity(0.20)
    static let listRowSelectedDark = Color.accentColor.opacity(0.30)

    // MARK: - 侧栏
    static let sidebarButtonSelected = Color.accentColor.opacity(0.15)
}
