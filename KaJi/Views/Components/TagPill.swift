//
//  TagPill.swift
//  KaJi
//
//  标签 pill：统一视觉样式。
//

import SwiftUI

struct TagPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let tag: String

    var body: some View {
        Text(tag)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                // v1.3.2：颜色统一走 SemanticColor.resolve(for:)
                Capsule()
                    .fill(KaJiColor.listRowHover.resolve(for: colorScheme))
            )
            .overlay(
                Capsule()
                    // v1.7.0：分隔线走 macOS hierarchical shape style .quaternary，自动跟随深浅模式
                    // （替代 v1.3.2 写死的 systemSeparator.opacity(0.35)）
                    .stroke(.quaternary, lineWidth: 0.5)
            )
    }
}
