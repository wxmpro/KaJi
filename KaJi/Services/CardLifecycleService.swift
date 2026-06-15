//
//  CardLifecycleService.swift
//  KaJi
//
//  卡片删除/恢复：软删除到回收站、从回收站还原，均带 Undo。
//

import SwiftUI
import AppKit

@MainActor
final class CardLifecycleService {
    private weak var editorState: EditorState?
    private weak var statsState: StatsState?
    private let cardService: CardService

    init(editorState: EditorState, statsState: StatsState, cardService: CardService = .shared) {
        self.editorState = editorState
        self.statsState = statsState
        self.cardService = cardService
    }

    /// 列表行/菜单删除入口：带 UndoManager 注册
    func softDelete(_ card: Card) {
        guard let editorState = editorState, let statsState = statsState else { return }

        do {
            try cardService.softDelete(id: card.id)
            if editorState.currentCard?.id == card.id {
                editorState.currentCard = nil
            }
            statsState.rebuildStats { [weak editorState] error in
                editorState?.saveError = "统计刷新失败：\(error.localizedDescription)"
            }

            editorState.undoManager?.registerUndo(withTarget: editorState) { target in
                target.restoreCard(card)
            }
            editorState.undoManager?.setActionName("删除卡片")
        } catch {
            editorState.saveError = "删除失败：\(error.localizedDescription)"
        }
    }

    /// Undo 入口：从回收站恢复卡片
    func restore(_ card: Card) {
        guard let editorState = editorState, let statsState = statsState else { return }

        do {
            try cardService.restore(id: card.id)
            editorState.currentCard = card
            statsState.rebuildStats { [weak editorState] error in
                editorState?.saveError = "统计刷新失败：\(error.localizedDescription)"
            }

            editorState.undoManager?.registerUndo(withTarget: editorState) { target in
                target.softDeleteCard(card)
            }
            editorState.undoManager?.setActionName("恢复卡片")
        } catch {
            editorState.saveError = "恢复失败：\(error.localizedDescription)"
        }
    }
}
