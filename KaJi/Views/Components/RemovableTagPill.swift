//
//  RemovableTagPill.swift
//  KaJi
//
//  v1.4.0：标签 pill 带叉叉小图标（hover/always 时显示），点击直接删除。
//  - canRemove = false 时（回收站只读）不显示叉叉按钮
//  - canRemove = true 时（编辑中）显示叉叉小图标
//

import SwiftUI

struct RemovableTagPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let tag: String
    let canRemove: Bool
    let onRemove: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            Text(tag)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.vertical, 2)

            if canRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: isHovering ? "xmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .padding(.vertical, 2)
                .help("删除标签")
            } else {
                Spacer().frame(width: 4)
            }
        }
        .background(
            Capsule()
                .fill(KaJiColor.listRowHover.resolve(for: colorScheme))
        )
        .overlay(
            Capsule()
                // v1.7.0：分隔线走 macOS hierarchical shape style .quaternary
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}