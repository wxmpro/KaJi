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
                // v1.3.0：颜色统一走 KaJiColor.listRowHover 常量
                Capsule()
                    .fill(colorScheme == .dark ? KaJiColor.listRowHoverDark : KaJiColor.listRowHoverLight)
            )
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
    }
}
