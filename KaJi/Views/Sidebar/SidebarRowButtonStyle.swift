//
//  SidebarRowButtonStyle.swift
//  KaJi
//
//  侧栏行按钮样式：hover / pressed 用系统 controlColor。
//

import SwiftUI

struct SidebarRowButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
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
    }

    private func fillColor(isPressed: Bool) -> Color {
        // v1.3.0：颜色统一走 KaJiColor 常量
        if isPressed {
            return colorScheme == .dark ? KaJiColor.cardBorderDark : KaJiColor.cardBorderLight
        }
        if isHovering {
            return colorScheme == .dark ? KaJiColor.listRowHoverDark : KaJiColor.listRowHoverLight
        }
        return .clear
    }
}
