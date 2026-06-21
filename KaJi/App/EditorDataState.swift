//
//  EditorDataState.swift
//  KaJi
//
//  编辑器状态层。DraftState 状态机 + 4 个状态入口 + 增量更新。
//

import SwiftUI
import AppKit
import os

@Observable
@MainActor
final class EditorDataState {
    // MARK: - 单一真相源
    var draft: DraftState = .empty()

    // MARK: - 编辑会话原点快照
    //
    // 问题：debounce 自动保存在"逐个清空字段"过程中，把每一步"部分清空"内容
    //   写进 DB，等卡片变空命中 isEmpty 分支时，DB 里原内容早已被覆盖成残缺态。
    //   旧实现用 dbCard（残缺）做回收站快照 + undo 快照 → 回收站丢内容、撤销恢复残缺。
    //
    // 解法：在编辑会话内持有"内容最丰满"的一版卡（按 contentCharCount 取峰值）。
    //   - startEditing 捕获打开时的原内容
    //   - 每次非空 commitDraft 持久化后，若更丰满则刷新峰值
    //   - 清空使字符数下降 → 峰值不动 → 始终保留清空前最完整内容
    //   清空到回收站时用它原子回写（内容 + deletedAt 一次落库），撤销也用它。
    @ObservationIgnored
    private var editSessionOrigin: Card?

    /// 刷新会话原点：仅当更丰满（或换了卡）时更新，保证持有峰值内容
    private func refreshEditSessionOrigin(with card: Card) {
        guard !card.isEmpty else { return }
        if let origin = editSessionOrigin, origin.id == card.id {
            if card.contentCharCount >= origin.contentCharCount {
                editSessionOrigin = card
            }
        } else {
            editSessionOrigin = card
        }
    }

    // MARK: - 依赖
    @ObservationIgnored
    private let cardService: CardService

    @ObservationIgnored
    private weak var statsState: StatsState?

    @ObservationIgnored
    private weak var listState: ListState?

    @ObservationIgnored
    weak var alert: EditorAlertState?

    @ObservationIgnored
    var undoManager: UndoManager?

    @ObservationIgnored
    private var typeChangeService: CardTypeChangeService!

    @ObservationIgnored
    private var lifecycleService: CardLifecycleService!

    @ObservationIgnored
    private static let log = Logger(subsystem: "com.kaji.app", category: "editor-state")

    init(
        statsState: StatsState,
        listState: ListState,
        alert: EditorAlertState,
        cardService: CardService = .shared
    ) {
        self.statsState = statsState
        self.listState = listState
        self.alert = alert
        self.cardService = cardService
        self.typeChangeService = CardTypeChangeService(data: self)
        self.lifecycleService = CardLifecycleService(data: self, statsState: statsState)
    }

    // MARK: - 状态入口 1：开新空白草稿

    /// 开新空白草稿
    /// - 修复 R4 bug：自动清空 draft.cardID
    func startNewDraft(typeId: String = "自由卡") {
        draft = .empty(typeId)
        editSessionOrigin = nil
        alert?.saveError = nil
        withAnimation(KaJiAnimation.modeSwitch) {
            listState?.listFilter = nil
            listState?.refreshFilteredCards()
            listState?.rightPaneMode = .editor
        }
    }

    // MARK: - 状态入口 2：打开已有卡

    /// 打开已有卡（自动判断编辑态 / 回收站只读态）
    func startEditing(_ card: Card) {
        draft = card.deletedAt != nil ? .trash(card) : .editing(card)
        // 回收站只读卡不参与编辑，无需快照
        editSessionOrigin = card.deletedAt == nil ? card : nil
        alert?.saveError = nil
        withAnimation(KaJiAnimation.modeSwitch) {
            listState?.rightPaneMode = .editor
        }
    }

    // MARK: - 状态入口 3：提交草稿

    /// 提交草稿（创建 UUID + 持久化）—— 唯一产生 ID 冲突重试的位置
    /// - Parameters:
    ///   - transform: 可选 transform 闭包；nil 时不修改 card，直接持久化当前 draft
    /// - Returns: 实际持久化后的 Card（ID 冲突重试后是新 ID 的 Card）
    /// 防御性：.trash 状态下拒绝持久化（即便 View 层 disabled 失效也不会写入）
    @discardableResult
    func commitDraft(transform: ((inout Card) -> Void)? = nil) async -> Result<Card, KaJiError> {
        guard !draft.isReadOnly else {
            Self.log.warning("commitDraft ignored: draft is read-only (.trash)")
            return .success(draft.card)
        }
        let isEmptyDraft = draft.isEmptyDraft
        var card = draft.card
        let draftTypeId = draft.cardTypeID

        if isEmptyDraft {
            do {
                let id = try CardIDGenerator.next()
                card = Card.new(
                    typeId: draftTypeId,
                    id: id,
                    title: card.title,
                    tags: card.tags,
                    fields: card.fields.reduce(into: [String: String]()) {
                        $0[$1.fieldName] = $1.fieldValue
                    }
                )
            } catch {
                Self.log.error("CardIDGenerator failed: \(error.localizedDescription, privacy: .public)")
                let err = KaJiError.unknown(error)
                alert?.saveError = err.errorDescription
                return .failure(err)
            }
        }

        if let transform {
            transform(&card)
        }

        if card.isEmpty {
            if isEmptyDraft {
                // 空草稿生成的空新卡：直接 discard
                draft = .empty(draftTypeId)
                editSessionOrigin = nil
                return .success(Card.placeholder)
            } else {
                // 用 editSessionOrigin（清空前最完整内容）原子回写 + 软删除。
                // editSessionOrigin 持有本次编辑会话的内容峰值（清空使字符数
                // 下降，不更新峰值）。softDeletePreservingContent 单事务把完整内容 +
                // deletedAt 一次落库，回收站显示完整原内容；undo 快照同样用它，
                // restore 后 DB 即完整内容，不再触发 isEmpty 分支 → 无死循环。
                precondition(card.deletedAt == nil,
                    "commitDraft 已持久化分支的 card 不应已删除（DraftState.editing 阶段 deletedAt 必须为 nil）")

                // 会话原点缺失（理论上不会发生）时退化为 DB 当前态，至少不崩
                let origin = editSessionOrigin ?? ((try? CardRepository.shared.card(id: card.id)) ?? card)
                var snapshot = origin
                snapshot.deletedAt = nil   // 快照本身保持"未删除"语义，供 restore 复原

                do {
                    try cardService.softDeletePreservingContent(snapshot)
                    let stats = try await cardService.refreshStats()
                    statsState?.update(with: stats)
                    // update(with:) 已通过 StatsState observer 在下一帧触发列表刷新，
                    // 不需要显式 refreshFilteredCards，避免双重 O(N) 过滤
                    undoManager?.registerUndo(withTarget: self) { target in
                        target.restoreFromTrash(snapshot)
                    }
                    undoManager?.setActionName("删除卡片")
                    draft = .empty(draftTypeId)
                    editSessionOrigin = nil
                } catch {
                    Self.log.error("commitDraft softDelete failed: \(error.localizedDescription, privacy: .public)")
                    let err = (error as? KaJiError) ?? .unknown(error)
                    alert?.saveError = err.errorDescription
                    return .failure(err)
                }
                return .success(snapshot)
            }
        }

        let toPersist: Card
        if ContentLimit.isOverLimit(card: card) {
            toPersist = ContentLimit.truncate(card)
        } else {
            toPersist = card
        }

        draft = .editing(toPersist)

        do {
            let saved = try await cardService.persist(card: toPersist)
            if saved.id != toPersist.id {
                draft = .editing(saved)
                Self.log.notice("ID conflict retried: \(toPersist.id) → \(saved.id)")
            }
            // 持久化成功后刷新会话原点峰值
            refreshEditSessionOrigin(with: saved)
            // 增量刷新统计 —— 只更新当前卡 summary，不重查全库
            let changedSummaries = await cardService.refreshStatsIncremental(changed: [saved])
            statsState?.applyIncremental(changed: changedSummaries, removed: [])
            return .success(saved)
        } catch {
            Self.log.error("commitDraft persist failed: \(error.localizedDescription, privacy: .public)")
            let err = (error as? KaJiError) ?? .unknown(error)
            alert?.saveError = err.errorDescription
            return .failure(err)
        }
    }

    // MARK: - 状态入口 4：丢弃草稿

    func discardDraft() {
        draft = .empty(draft.cardTypeID)
    }

    // MARK: - 增量更新

    func updateDraft(_ block: (inout Card) -> Void) {
        guard case .editing(var card) = draft else { return }
        block(&card)
        draft = .editing(card)
    }

    // MARK: - 派生属性

    var currentCard: Card? {
        switch draft {
        case .empty: return nil
        case .editing(let c), .trash(let c): return c
        }
    }

    var currentCardTypeID: String { draft.cardTypeID }
    var currentCardTags: [String] { draft.tags }
    var selectedCardID: String? { draft.cardID }

    // MARK: - 卡片生命周期

    func softDeleteDraft() {
        guard case .editing(let card) = draft else { return }
        lifecycleService.softDelete(card)
        editSessionOrigin = nil
    }

    /// 统一走 lifecycleService（Bug 10 修复）
    func softDeleteCard(_ card: Card) {
        let wasCurrent = draft.cardID == card.id
        lifecycleService.softDelete(card)
        if wasCurrent { editSessionOrigin = nil }
    }

    func softDeleteCardByID(_ id: String) {
        guard let card = try? CardRepository.shared.card(id: id) else { return }
        softDeleteCard(card)
    }

    func restoreFromTrash(_ card: Card) {
        lifecycleService.restore(card)
        // 撤销/恢复后重建会话原点，保证之后再次清空仍持有完整内容峰值
        if case .editing(let c) = draft { editSessionOrigin = c }
    }

    // MARK: - 类型切换

    func requestCardTypeChange(to typeId: String) {
        typeChangeService.requestChange(to: typeId)
    }

    func confirmPendingCardTypeChange() {
        typeChangeService.confirmPendingChange()
    }

    func undoCardTypeChange(to typeId: String, fields: [CardField]) {
        typeChangeService.undoChange(to: typeId, fields: fields)
    }

    // MARK: - 剪贴板

    func copyAllContentToPasteboard() {
        guard !draft.card.isPlaceholder else { return }
        cardService.copyAllContentToPasteboard(for: draft.card)
    }
}
