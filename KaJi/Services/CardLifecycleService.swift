//
//  CardLifecycleService.swift
//  KaJi
//
//  卡片删除/恢复：软删除到回收站、从回收站还原，均带 Undo。
//
//  v1.4.0 状态机彻底重构：
//  - @MainActor 保持不变
//  - 内部走新状态机：软删除后切到 .empty（如果是当前 draft），恢复后切到 .editing
//  - flushSave 改为 await commitDraft
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

    /// 软删除（与 v1.3.4 行为完全一致 + v1.4.0 draft 转换 + v1.4.1 死循环修复）
    func softDelete(_ card: Card) {
        guard let data = data else { return }

        // v1.4.1：直接 cancel pending save（不再 fire-and-forget commitDraft）
        // 原因：v1.4.0 的 `Task { commitDraft { _ in } }` 在撤销时会导致 commitDraft
        // 走 isEmpty 分支又注册 undo + softDelete，撤销栈持续增长，软件卡死。
        cardService.cancelPendingSave()

        do {
            try cardService.softDelete(id: card.id)
            // v1.4.0：删的是当前 draft → 切到 .empty()
            if data.draft.cardID == card.id {
                data.draft = .empty(data.draft.cardType)
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

    /// 从回收站恢复（与 v1.3.4 行为完全一致 + v1.4.0 draft 转换 + v1.4.1 死循环修复）
    func restore(_ card: Card) {
        guard let data = data else { return }

        // v1.4.1：直接 cancel pending save（不再 fire-and-forget commitDraft）
        // 原因：v1.4.0 的 `Task { commitDraft { _ in } }` 会看到 draft=.editing(空 card)
        // 又走 isEmpty 分支注册 undo + softDelete，撤销栈持续增长，软件卡死。
        cardService.cancelPendingSave()

        do {
            try cardService.restore(id: card.id)
            // v1.4.0：恢复后切到 .editing
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
