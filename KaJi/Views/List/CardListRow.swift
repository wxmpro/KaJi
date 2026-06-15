//
//  CardListRow.swift
//  KaJi
//
//  卡片列表单行。
//

import SwiftUI

struct CardListRow: View {
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var editorState: EditorState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    let card: Card

    var body: some View {
        // v1.2.6+ UI 新增：列表行 hover 效果（跟侧栏同色：light=Color.gray.opacity(0.20)，dark=Color.white.opacity(0.10)）
        HStack(spacing: 0) {
            // 左侧垂直彩色条
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(card.cardType.color)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                // 标题
                Text(card.title.isEmpty ? "无标题" : card.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(card.title.isEmpty ? .secondary : .primary)

                // 元信息行：类型 + 标签
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(card.cardType.color)
                            .frame(width: 6, height: 6)
                        Text(card.cardType.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if !card.tags.isEmpty {
                        ForEach(card.tags.prefix(5), id: \.self) { tag in
                            TagPill(tag: tag)
                        }
                    }
                }
            }
            .padding(.leading, 12)

            Spacer(minLength: 16)

            // 右侧：14 位显示 ID
            Text(card.displayID)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            // v1.2.7：列表行 hover 背景改成圆角矩形（6pt 圆角，跟侧栏 SidebarRowButtonStyle 一致）
            // 之前是直接 fill Color,显示为长方形,跟整张卡的"圆角矩形"风格不一致
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering
                    ? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.gray.opacity(0.20))
                    : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("打开") {
                listState.openCardFromList(card, editorState: editorState)
            }
            Button("移到回收站", role: .destructive) {
                editorState.softDeleteCard(card)
            }
        }
    }
}
