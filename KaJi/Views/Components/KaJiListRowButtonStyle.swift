//
//  KaJiListRowButtonStyle.swift
//  KaJi
//
//  列表行按钮样式：选中态 / 按下态用深灰，hover 用浅灰，
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
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
                    .padding(.horizontal, 4)
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(KaJiAnimation.selection, value: configuration.isPressed)
            .animation(KaJiAnimation.selection, value: isSelected)
            .animation(KaJiAnimation.selection, value: isHovering)
    }

    /// 优先级：selected（持久）> pressed（按下瞬间）> hover > resting。
    /// selected / pressed 用不同色，便于区分「已选中」和「正在按」。
    private func fillColor(isPressed: Bool) -> Color {
        if isSelected {
            return KaJiColor.listRowSelected.resolve(for: colorScheme)
        }
        if isPressed {
            return KaJiColor.listRowPressed.resolve(for: colorScheme)
        }
        if isHovering {
            return KaJiColor.listRowHover.resolve(for: colorScheme)
        }
        return .clear
    }
}