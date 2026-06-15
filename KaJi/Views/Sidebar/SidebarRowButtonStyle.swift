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
        // v1.2.6+ UI 调整：候选 A
        // 旧：Color(nsColor: .controlColor).opacity(0.55/0.80)（light 模式下接近白色）
        // 新：固定灰色（light 模式 Color.gray.opacity(0.20)，dark 模式 Color.white.opacity(0.10)）
        // 用户记得之前是"灰色"——这是恢复性调整
        if isPressed {
            return colorScheme == .dark ? Color.white.opacity(0.15) : Color.gray.opacity(0.30)
        }
        if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.10) : Color.gray.opacity(0.20)
        }
        return .clear
    }
}
