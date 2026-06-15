//
//  CardTypeChangeService.swift
//  KaJi
//
//  卡片类型切换：含 Undo/Redo、确认弹窗逻辑。
//  与具体写盘解耦，只操作 EditorState 的 UI 状态并通过 editorState.saveImmediately 落库。
//

import SwiftUI
import AppKit

@MainActor
final class CardTypeChangeService {
    private weak var editorState: EditorState?

    init(editorState: EditorState) {
        self.editorState = editorState
    }

    /// 当前卡片是否已有内容
    private func currentCardHasContent() -> Bool {
        guard let card = editorState?.currentCard else { return false }
        if !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return card.fields.contains {
            !$0.fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 用户请求切换卡片类型：有内容时弹出确认，无内容时直接切换
    func requestChange(to type: CardType) {
        guard let editorState = editorState, type != editorState.currentCardType else { return }
        if currentCardHasContent() {
            editorState.pendingCardType = type
            editorState.showingTypeChangeAlert = true
        } else {
            applyChange(to: type)
        }
    }

    /// 确认切换：清空字段并按新类型重建结构
    func confirmPendingChange() {
        guard let editorState = editorState, let type = editorState.pendingCardType else { return }
        applyChange(to: type)
        editorState.pendingCardType = nil
    }

    private func applyChange(to type: CardType) {
        guard let editorState = editorState, var card = editorState.currentCard else { return }
        let previousType = editorState.currentCardType
        let previousFields = card.fields

        editorState.undoManager?.registerUndo(withTarget: editorState) { target in
            target.undoCardTypeChange(to: previousType, fields: previousFields)
        }
        editorState.undoManager?.setActionName("切换卡片类型")

        editorState.currentCardType = type
        card.type = type.rawValue
        card.fields = type.fields.enumerated().map { idx, name in
            CardField(cardId: card.id, fieldName: name, fieldValue: "", fieldOrder: idx)
        }
        editorState.currentCard = card
        editorState.saveImmediately()
    }

    /// Undo 入口：恢复卡片类型和字段
    func undoChange(to type: CardType, fields: [CardField]) {
        guard let editorState = editorState, var card = editorState.currentCard else { return }

        let currentType = editorState.currentCardType
        let currentFields = card.fields
        editorState.undoManager?.registerUndo(withTarget: editorState) { target in
            target.undoCardTypeChange(to: currentType, fields: currentFields)
        }
        editorState.undoManager?.setActionName("切换卡片类型")

        editorState.currentCardType = type
        card.type = type.rawValue
        card.fields = fields
        editorState.currentCard = card
        editorState.saveImmediately()
    }
}
