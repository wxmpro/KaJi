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
                // v1.2.6+ UI 调整：候选 A
                // 旧：Color(nsColor: .controlBackgroundColor)（light 模式下与窗口背景几乎融合，"突兀"）
                // 新：与侧栏/列表行 hover 同色（light=Color.gray.opacity(0.20)，dark=Color.white.opacity(0.10)）
                // 用户要求：tag 背景不随卡片类型变化（所有 tag 统一颜色）
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.gray.opacity(0.20))
            )
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
    }
}
