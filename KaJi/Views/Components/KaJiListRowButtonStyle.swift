//
//  KaJiListRowButtonStyle.swift
//  KaJi
//
//  列表行按钮样式（v1.3.1）：选中态 / 按下态用深灰，hover 用浅灰，
//  与侧栏 SidebarRowButtonStyle 视觉同源，深浅模式统一。
//
//  设计要点：
//  - 不依赖 SwiftUI List(selection:)，由调用方传 isSelected 进来，
//    这样能完全控制选中色（系统 List 选中色是 accentColor 蓝色，无法改）。
//  - 三态色阶：clear（resting）→ listRowHover（hover）→ cardBorder（pressed/selected）。
//  - 颜色过渡走 KaJiAnimation.selection，保证侧栏与列表动效一致。
//

import SwiftUI

struct KaJiListRowButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
                    .padding(.horizontal, 4)
            )
            .animation(KaJiAnimation.selection, value: configuration.isPressed)
            .animation(KaJiAnimation.selection, value: isSelected)
    }

    /// 优先级：selected（持久）> pressed（按下瞬间）> resting。
    /// selected 与 pressed 用同色（cardBorder），保持视觉连贯。
    private func fillColor(isPressed: Bool) -> Color {
        if isSelected || isPressed {
            return KaJiColor.listRowSelected.resolve(for: colorScheme)
        }
        return .clear
    }
}