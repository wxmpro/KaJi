//
//  CardTypeChangeService.swift
//  KaJi
//
//  卡片类型切换：含 Undo/Redo、确认弹窗逻辑。
//  与具体写盘解耦，只操作 data / alert 子 state 的 UI 状态并通过 data.saveImmediately 落库。
//
//  v1.2.9 T2 改造：构造签名从 (editorState) 改为 (data)，
//  内部不再订阅完整 EditorState，只用 dataState 持有 currentCard / currentCardType /
//  flushSave / saveImmediately / undoManager 和 alertState 写 pendingCardType /
//  showingTypeChangeAlert。
//

import SwiftUI
import AppKit

@MainActor
final class CardTypeChangeService {
    private weak var data: EditorDataState?

    init(data: EditorDataState) {
        self.data = data
    }

    /// 当前卡片是否已有内容
    private func currentCardHasContent() -> Bool {
        guard let card = data?.currentCard else { return false }
        if !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return card.fields.contains {
            !$0.fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 用户请求切换卡片类型：有内容时弹出确认，无内容时直接切换
    func requestChange(to type: CardType) {
        guard let data = data, let alert = data.alert, type != data.currentCardType else { return }
        if currentCardHasContent() {
            alert.pendingCardType = type
            alert.showingTypeChangeAlert = true
        } else {
            applyChange(to: type)
        }
    }

    /// 确认切换：清空字段并按新类型重建结构
    func confirmPendingChange() {
        guard let data = data, let alert = data.alert, let type = alert.pendingCardType else { return }
        applyChange(to: type)
        alert.pendingCardType = nil
    }

    private func applyChange(to type: CardType) {
        guard let data = data, var card = data.currentCard else { return }
        let previousType = data.currentCardType
        let previousFields = card.fields

        // T1 P0 修复（v1.2.9）：先 flush 当前正在编辑的内容到 SQLite，避免类型切换后
        // pending save 把刚切换的 fields 覆盖回旧内容。
        data.flushSave()

        data.undoManager?.registerUndo(withTarget: data) { target in
            target.undoCardTypeChange(to: previousType, fields: previousFields)
        }
        data.undoManager?.setActionName("切换卡片类型")

        data.currentCardType = type
        card.type = type.rawValue
        card.fields = type.fields.enumerated().map { idx, name in
            CardField(cardId: card.id, fieldName: name, fieldValue: "", fieldOrder: idx)
        }
        data.currentCard = card
        data.saveImmediately()
    }

    /// Undo 入口：恢复卡片类型和字段
    func undoChange(to type: CardType, fields: [CardField]) {
        guard let data = data, var card = data.currentCard else { return }

        let currentType = data.currentCardType
        let currentFields = card.fields

        // T1 P0 修复（v1.2.9）：先 flush 取消 pending save，避免旧内容覆盖 undo 后的状态。
        data.flushSave()

        data.undoManager?.registerUndo(withTarget: data) { target in
            target.undoCardTypeChange(to: currentType, fields: currentFields)
        }
        data.undoManager?.setActionName("切换卡片类型")

        data.currentCardType = type
        card.type = type.rawValue
        card.fields = fields
        data.currentCard = card
        data.saveImmediately()
    }
}
