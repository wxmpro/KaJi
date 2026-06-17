//
//  CardTypeChangeService.swift
//  KaJi
//
//  卡片类型切换：含 Undo/Redo、确认弹窗逻辑。
//  v1.4.0：内部走新状态机；draft.setType 处理空草稿 type 切换
//
//  v1.4.0 Bug 1 修复：空草稿 type 切换通过 draft.setType 实现
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
    func requestChange(to type: CardType) {
        guard let data = data, let alert = data.alert, type != data.draft.cardType else { return }

        // 修复 Bug 1：空草稿直接通过 draft.setType 切换类型，不弹窗
        if case .empty = data.draft {
            data.draft.setType(type)
            return
        }

        if currentCardHasContent() {
            alert.pendingCardType = type
            alert.showingTypeChangeAlert = true
        } else {
            applyChange(to: type)
        }
    }

    func confirmPendingChange() {
        guard let data = data, let alert = data.alert, let type = alert.pendingCardType else { return }
        applyChange(to: type)
        alert.pendingCardType = nil
    }

    private func applyChange(to type: CardType) {
        guard let data = data else { return }

        // v1.4.0：先 flush 当前正在编辑的内容
        Task { @MainActor in
            _ = await data.commitDraft()
        }

        // 修复：updateDraft 闭包外捕获 previousFields，避免 inout 闭包内的引用问题
        let previousType = data.draft.cardType
        let previousFields = data.draft.card.fields

        data.updateDraft { card in
            card.type = type.rawValue
            card.fields = type.fields.enumerated().map { idx, name in
                CardField(cardId: card.id, fieldName: name, fieldValue: "", fieldOrder: idx)
            }
            data.undoManager?.registerUndo(withTarget: data) { target in
                target.undoCardTypeChange(to: previousType, fields: previousFields)
            }
            data.undoManager?.setActionName("切换卡片类型")
        }
    }

    func undoChange(to type: CardType, fields: [CardField]) {
        guard let data = data else { return }
        let currentType = data.draft.cardType
        let currentFields = data.draft.card.fields

        Task { @MainActor in
            _ = await data.commitDraft()
        }

        data.updateDraft { card in
            card.type = type.rawValue
            card.fields = fields
            data.undoManager?.registerUndo(withTarget: data) { target in
                target.undoCardTypeChange(to: currentType, fields: currentFields)
            }
            data.undoManager?.setActionName("切换卡片类型")
        }
    }
}