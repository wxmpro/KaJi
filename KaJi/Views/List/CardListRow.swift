//
//  CardListRow.swift
//  KaJi
//
//  卡片列表单行。选中态判断走 data.draft.cardID（@Observable 自动追踪）。
//

import SwiftUI

struct CardListRow: View {
    @Environment(ListState.self) private var listState
    @Environment(EditorDataState.self) private var data
    @Environment(\.colorScheme) private var colorScheme

    let card: CardSummary

    private var isSelected: Bool {
        data.draft.cardID == card.id
    }

    var body: some View {
        Button {
            openCardFromRow()
        } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(card.cardTypeDef.color)
                    .frame(width: 4)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title.isEmpty ? "无标题" : card.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(card.title.isEmpty ? .secondary : .primary)

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(card.cardTypeDef.color)
                                .frame(width: 6, height: 6)
                            Text(card.cardTypeDef.name)
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
                openCardFromRow()
            }
            if listState.listFilter == .trash {
                Button("恢复") {
                    if let fullCard = try? CardRepository.shared.card(id: card.id) {
                        data.restoreFromTrash(fullCard)
                    }
                }
            } else {
                Button("移到回收站", role: .destructive) {
                    if let fullCard = try? CardRepository.shared.card(id: card.id) {
                        data.softDeleteCard(fullCard)
                    }
                }
            }
        }
    }

    /// 打开卡片进编辑器（异步读，避免主线程 I/O 阻塞）
    private func openCardFromRow() {
        Task { @MainActor in
            guard let fullCard = try? await CardRepository.shared.cardAsync(id: card.id) else { return }
            data.startEditing(fullCard)
            withAnimation(KaJiAnimation.modeSwitch) {
                listState.rightPaneMode = .editor
            }
        }
    }
}
