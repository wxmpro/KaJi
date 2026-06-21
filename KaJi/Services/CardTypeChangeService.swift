//
//  CardTypeChangeService.swift
//  KaJi
//
//  卡片类型切换：含 Undo/Redo、确认弹窗逻辑。
//  内部走新状态机；空草稿 type 切换通过 draft.setType 实现（不弹窗）。
//

import SwiftUI
import AppKit

@MainActor
final class CardTypeChangeService {
    @ObservationIgnored
    private weak var data: EditorDataState?

    init(data: EditorDataState) {
        self.data = data
    }

    /// 当前卡片是否已有内容
    private func currentCardHasContent() -> Bool {
        guard let data = data else { return false }
        let card = data.draft.card
        if !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !data.draft.tags.isEmpty { return true }
        return card.fields.contains {
            !$0.fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 用户请求切换卡片类型
    func requestChange(to typeId: String) {
        guard let data = data, let alert = data.alert, typeId != data.draft.cardTypeID else { return }

        // 空草稿直接通过 draft.setType 切换类型，不弹窗
        if case .empty = data.draft {
            data.draft.setType(typeId)
            return
        }

        if currentCardHasContent() {
            alert.pendingCardType = typeId
            alert.showingTypeChangeAlert = true
        } else {
            applyChange(to: typeId)
        }
    }

    func confirmPendingChange() {
        guard let data = data, let alert = data.alert, let typeId = alert.pendingCardType else { return }
        applyChange(to: typeId)
        alert.pendingCardType = nil
    }

    private func applyChange(to typeId: String) {
        guard let data = data else { return }

        let previousTypeId = data.draft.cardTypeID
        let previousFields = data.draft.card.fields
        let registry = CardTypeRegistry.shared
        let newFieldNames = registry.allFields(for: typeId)

        Task { @MainActor in
            _ = await data.commitDraft()

            data.updateDraft { card in
                card.type = typeId
                card.fields = newFieldNames.enumerated().map { idx, name in
                    CardField(cardId: card.id, fieldName: name, fieldValue: "", fieldOrder: idx)
                }
            }
            _ = await data.commitDraft()

            data.undoManager?.registerUndo(withTarget: data) { target in
                target.undoCardTypeChange(to: previousTypeId, fields: previousFields)
            }
            data.undoManager?.setActionName("切换卡片类型")
        }
    }

    func undoChange(to typeId: String, fields: [CardField]) {
        guard let data = data else { return }
        let currentTypeId = data.draft.cardTypeID
        let currentFields = data.draft.card.fields

        Task { @MainActor in
            _ = await data.commitDraft()

            data.updateDraft { card in
                card.type = typeId
                card.fields = fields
            }
            _ = await data.commitDraft()

            data.undoManager?.registerUndo(withTarget: data) { target in
                target.undoCardTypeChange(to: currentTypeId, fields: currentFields)
            }
            data.undoManager?.setActionName("切换卡片类型")
        }
    }
}