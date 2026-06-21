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
    @ObservationIgnored
    private weak var data: EditorDataState?

    @ObservationIgnored
    private weak var statsState: StatsState?

    @ObservationIgnored
    private let cardService: CardService

    init(data: EditorDataState, statsState: StatsState?, cardService: CardService = .shared) {
        self.data = data
        self.statsState = statsState
        self.cardService = cardService
    }

    /// 软删除。删的是当前 draft → 切到 .empty()。
    func softDelete(_ card: Card) {
        guard let data = data else { return }

        // 直接 cancel pending save（不 fire-and-forget commitDraft）
        // 否则撤销时 commitDraft 走 isEmpty 分支又注册 undo + softDelete，
        // 撤销栈持续增长，软件卡死。
        cardService.cancelPendingSave()

        do {
            try cardService.softDelete(id: card.id)
            if data.draft.cardID == card.id {
                data.draft = .empty(data.draft.cardTypeID)
            }
            statsState?.rebuildStats { [weak self] error in
                self?.data?.alert?.saveError = "统计刷新失败：\(error.localizedDescription)"
            }
            data.undoManager?.registerUndo(withTarget: data) { target in
                target.restoreFromTrash(card)
            }
            data.undoManager?.setActionName("删除卡片")
        } catch {
            data.alert?.saveError = "删除失败：\(error.localizedDescription)"
        }
    }

    /// 从回收站恢复。恢复后切到 .editing。
    func restore(_ card: Card) {
        guard let data = data else { return }

        // 直接 cancel pending save（不 fire-and-forget commitDraft）
        // 否则会看到 draft=.editing(空 card) 又走 isEmpty 分支注册 undo + softDelete。
        cardService.cancelPendingSave()

        do {
            try cardService.restore(id: card.id)
            data.draft = .editing(card)
            statsState?.rebuildStats { [weak self] error in
                self?.data?.alert?.saveError = "统计刷新失败：\(error.localizedDescription)"
            }
            data.undoManager?.registerUndo(withTarget: data) { target in
                target.softDeleteCard(card)
            }
            data.undoManager?.setActionName("恢复卡片")
        } catch {
            data.alert?.saveError = "恢复失败：\(error.localizedDescription)"
        }
    }
}
