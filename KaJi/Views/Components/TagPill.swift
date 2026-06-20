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
                Capsule()
                    .fill(KaJiColor.listRowHover.resolve(for: colorScheme))
            )
            .overlay(
                Capsule()
                    .stroke(.quaternary, lineWidth: 0.5)
            )
    }
}
