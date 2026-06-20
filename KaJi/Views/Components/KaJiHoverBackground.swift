//
//  KaJiHoverBackground.swift
//  KaJi
//
//  统一按钮 hover 样式：hover 时浮现系统 controlColor。
//

import SwiftUI

struct KaJiHoverBackground: ViewModifier {
    var cornerRadius: CGFloat
    var restingBackground: Color
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? hoverColor : restingBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private var hoverColor: Color {
        KaJiColor.listRowHover.resolve(for: colorScheme)
    }
}

extension View {
    func kajiHover(cornerRadius: CGFloat = 6, restingBackground: Color = .clear) -> some View {
        modifier(KaJiHoverBackground(cornerRadius: cornerRadius, restingBackground: restingBackground))
    }
}
