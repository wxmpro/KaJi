//
//  EditorDataState.swift
//  KaJi
//
//  v1.4.0 状态机彻底重构：
//  - 5 个 @Published → 1 个 draft @Observable 字段
//  - 4 个状态入口（startNewDraft / startEditing / commitDraft / discardDraft）
//  - 增量更新 updateDraft
//
//  v1.4.0 一次性修复（不再有 dead API / 兼容层）：
//  - 删除 v1.3.4 startNewCard / openCard / restoreCard 兼容层（无调用方）
//  - 删除 saveImmediately / flushSave 死 API（无调用方，已被 commitDraft 替代）
//  - 删 lastSavedAt / hasBeenPersisted / ensureCurrentCardID / persistCurrentCard
//  - Bug 1-10 全部修复
//

import SwiftUI
import AppKit
import os

@Observable
@MainActor
final class EditorDataState {
    // MARK: - 单一真相源
    var draft: DraftState = .empty()

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
    func startNewDraft(type: CardType = .free) {
        draft = .empty(type)
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
        let draftType = draft.cardType

        if isEmptyDraft {
            do {
                let id = try CardIDGenerator.next()
                card = Card.new(
                    type: draftType,
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
                draft = .empty(draftType)
                return .success(Card.placeholder)
            } else {
                // 已持久化空卡：先 persist 当前空内容到 DB，再 softDelete 设置 deletedAt，
                // 最后同步刷新 stats 和 list（与正常 persist 路径一致），并注册 undo。
                //
                // 为什么先 persist 再 softDelete：
                // scheduleSave 是 800ms debounce；用户清空字段/标签时如果操作间隔 > 800ms，
                // 中间多次 commitDraft 会把"部分清空"的内容 persist 到 DB，最后 isEmpty 分支
                // 不 persist 就 softDelete 时，DB 中是部分清空 + deletedAt，回收站里看到的是
                // 残缺内容或空卡，体验割裂。先 persist 一次当前空内容可以保证 DB 中是确定
                // 状态（清空后的内容），回收站里至少有一张空卡可点开。
                //
                // 为什么不用 lifecycleService.softDelete（与之前一样避免）：
                // 它内部会再调 data.commitDraft，形成 commitDraft → lifecycleService →
                // commitDraft 循环，把空内容覆盖到 DB（v1.3.4 PATCH 已观察到的 bug）。
                // 这里手动调 cardService.softDelete + 注册 undo，等价于 v1.3.4 行为。
                precondition(card.deletedAt == nil,
                    "commitDraft 已持久化分支的 card 不应已删除（DraftState.editing 阶段 deletedAt 必须为 nil）")
                do {
                    // 1. 先 persist 当前空内容到 DB（覆盖中间 commit 的部分清空状态）
                    _ = try await cardService.persist(card: card)
                    // 2. 再 softDelete 设置 deletedAt
                    try cardService.softDelete(id: card.id)
                    // 3. 同步刷新 stats 和 list（与正常 persist 路径完全一致，
                    //    不依赖 observer 异步触发，避免用户切到回收站时 ListState 还是旧值）
                    let stats = try await cardService.refreshStats()
                    statsState?.update(with: stats)
                    listState?.refreshFilteredCards()
                    // 4. 注册 undo（v1.3.4 PATCH 的"带 undo 注册"语义）— 走 restoreFromTrash
                    //    等价于 v1.3.4 的 restoreCard 路径：lifecycleService.restore 内部
                    //    commitDraft 在 draft=.empty 状态会走 discard 分支，不会形成循环。
                    let snapshot = card
                    undoManager?.registerUndo(withTarget: self) { target in
                        target.restoreFromTrash(snapshot)
                    }
                    undoManager?.setActionName("删除卡片")
                    draft = .empty(draftType)
                } catch {
                    Self.log.error("commitDraft softDelete failed: \(error.localizedDescription, privacy: .public)")
                    let err = (error as? KaJiError) ?? .unknown(error)
                    alert?.saveError = err.errorDescription
                    return .failure(err)
                }
                return .success(card)
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
            let stats = try await cardService.refreshStats()
            statsState?.update(with: stats)
            listState?.refreshFilteredCards()
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
        draft = .empty(draft.cardType)
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

    var currentCardType: CardType { draft.cardType }
    var currentCardTags: [String] { draft.tags }
    var selectedCardID: String? { draft.cardID }

    // MARK: - 卡片生命周期

    func softDeleteDraft() {
        guard case .editing(let card) = draft else { return }
        lifecycleService.softDelete(card)
    }

    /// 统一走 lifecycleService（Bug 10 修复）
    func softDeleteCard(_ card: Card) {
        lifecycleService.softDelete(card)
    }

    func softDeleteCardByID(_ id: String) {
        guard let card = try? CardRepository.shared.card(id: id) else { return }
        softDeleteCard(card)
    }

    func restoreFromTrash(_ card: Card) {
        lifecycleService.restore(card)
    }

    // MARK: - 类型切换

    func requestCardTypeChange(to type: CardType) {
        typeChangeService.requestChange(to: type)
    }

    func confirmPendingCardTypeChange() {
        typeChangeService.confirmPendingChange()
    }

    func undoCardTypeChange(to type: CardType, fields: [CardField]) {
        typeChangeService.undoChange(to: type, fields: fields)
    }

    // MARK: - 剪贴板

    func copyAllContentToPasteboard() {
        guard !draft.card.isPlaceholder else { return }
        cardService.copyAllContentToPasteboard(for: draft.card)
    }
}