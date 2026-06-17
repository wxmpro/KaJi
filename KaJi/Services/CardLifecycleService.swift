//
//  CardLifecycleService.swift
//  KaJi
//
//  卡片删除/恢复：软删除到回收站、从回收站还原，均带 Undo。
//
//  v1.2.9 T2 改造：构造签名从 (editorState, statsState) 改为 (data, alert, statsState)，
//  内部不再订阅完整 EditorState，只用 dataState 持有 currentCard / flushSave / undoManager
//  和 alertState 写 saveError。
//

import SwiftUI
import AppKit

@MainActor
final class CardLifecycleService {
    private weak var data: EditorDataState?
    private weak var statsState: StatsState?
    private let cardService: CardService

    // v1.3.0：statsState 改 optional（与 EditorDataState.weak var statsState: StatsState? 一致）
    init(data: EditorDataState, statsState: StatsState?, cardService: CardService = .shared) {
        self.data = data
        self.statsState = statsState
        self.cardService = cardService
    }

    /// 列表行/菜单删除入口：带 UndoManager 注册
    func softDelete(_ card: Card) {
        // v1.3.4 PATCH：guard 降级，核心 SQLite 写盘 + Undo 注册不再被 statsState/alert 阻塞
        guard let data = data else { return }

        // T1 P0 修复（v1.2.9）：先 flush 取消 pending save，把当前编辑器最新
        // 内容立即落库。否则 pending 的旧 content 会在删除完成后覆盖 deletedAt，
        // 复活已删除的卡。
        data.flushSave()

        do {
            try cardService.softDelete(id: card.id)
            // v1.2.9 T3 配套：data.currentCard 和 selectedCardID 的清空
            // 已由 EditorDataState.softDeleteCard 在调本 service 前完成,
            // service 这里不再重复写状态
            statsState?.rebuildStats { [weak self] error in
                self?.data?.alert?.saveError = "统计刷新失败：\(error.localizedDescription)"
            }

            data.undoManager?.registerUndo(withTarget: data) { target in
                target.restoreCard(card)
            }
            data.undoManager?.setActionName("删除卡片")
        } catch {
            data.alert?.saveError = "删除失败：\(error.localizedDescription)"
        }
    }

    /// Undo 入口：从回收站恢复卡片
    func restore(_ card: Card) {
        // v1.3.4 PATCH：guard 降级，核心 SQLite 写盘 + Undo 注册不再被 statsState/alert 阻塞
        guard let data = data else { return }

        // T1 P0 修复（v1.2.9）：先 flush 取消 pending save，避免旧内容覆盖
        // 恢复后的字段。
        data.flushSave()

        do {
            try cardService.restore(id: card.id)
            data.currentCard = card
            // v1.3.4 PATCH：恢复后同步类型和标签，避免编辑器字段结构与卡片实际内容不一致
            data.currentCardType = card.cardType
            data.currentCardTags = card.tags
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
