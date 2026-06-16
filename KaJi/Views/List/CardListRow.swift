//
//  CardListRow.swift
//  KaJi
//
//  卡片列表单行。
//
//  v1.2.9 T5 改造：card: Card → card: CardSummary（轻量）
//  v1.3.1 改造：弃用 SwiftUI List(selection:)，改用 Button + KaJiListRowButtonStyle，
//  这样选中色能完全自定义（系统 List 选中色固定 accentColor，无法统一为深灰）。
//  selected 判定走 data.selectedCardID（v1.2.9 T3 引入，单一数据源）。
//

import SwiftUI

struct CardListRow: View {
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var editorState: EditorState
    @EnvironmentObject var data: EditorDataState
    @Environment(\.colorScheme) private var colorScheme

    let card: CardSummary

    private var isSelected: Bool {
        data.selectedCardID == card.id
    }

    var body: some View {
        Button {
            // 与原 List(selection:) 行为一致：设置选中 + 加载到编辑器
            data.selectedCardID = card.id
            listState.openCardFromList(card, editorState: editorState)
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(KaJiListRowButtonStyle(colorScheme: colorScheme, isSelected: isSelected))
        .contextMenu {
            Button("打开") {
                listState.openCardFromList(card, editorState: editorState)
            }
            Button("移到回收站", role: .destructive) {
                // v1.3.0：直连 data.softDeleteCardByID（删 facade 后）
                editorState.data.softDeleteCardByID(card.id)
            }
        }
    }
}