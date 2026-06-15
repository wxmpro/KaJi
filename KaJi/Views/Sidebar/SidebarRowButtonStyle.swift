//
//  SidebarRowButtonStyle.swift
//  KaJi
//
//  侧栏行按钮样式：hover / pressed 用系统 controlColor。
//

import SwiftUI

struct SidebarRowButtonStyle: ButtonStyle {
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
        if isPressed { return Color(nsColor: .controlColor).opacity(0.80) }
        if isHovering { return Color(nsColor: .controlColor).opacity(0.55) }
        return .clear
    }
}
