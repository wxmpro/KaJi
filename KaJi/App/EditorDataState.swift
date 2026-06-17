//
//  EditorDataState.swift
//  KaJi
//
//  数据状态层。
//  v1.2.9 T2 改造：原 EditorState 中跨"数据/UI/告警"三类的 11 个 @Published
//  按生命周期拆分到 3 个独立 ObservableObject。本文件承载：
//    - 当前卡片数据（currentCard / currentCardType / currentCardTags）
//    - 持久化协调（lastSavedAt — 通知 UI 上次保存时间）
//    - 数据态业务方法（startNewCard / openCard / saveImmediately / flushSave /
//      softDeleteCard / restoreCard / requestCardTypeChange / 等）
//
//  业务方法从 EditorState 容器迁移过来；EditorState 保留 facade 转发保证
//  KaJiApp 顶层菜单不破。
//
//  Alert 相关写操作（saveError / pendingCardType / showingTypeChangeAlert）
//  走 alert: EditorAlertState（init 注入）。
//

import SwiftUI
import AppKit

@MainActor
final class EditorDataState: ObservableObject {
    // MARK: - 当前态
    @Published var currentCard: Card?
    @Published var currentCardType: CardType = .free
    @Published var currentCardTags: [String] = []

    // MARK: - 列表选择（v1.2.9 T3 修复）
    // 原 List(selection:) 绑到 currentCard?.id，但 currentCard 是完整 Card
    // 结构体，编辑时任何字段变更都触发 CardListView 重建，List 的 selection
    // 状态重新同步，导致从列表点开卡 → 返回后该卡下方出现灰色高亮漂移。
    // 改用独立 String? 字段作为 selection 的单一数据源，只有 id 变化时才通知
    // List 重建 selection。
    @Published var selectedCardID: String?

    // MARK: - 持久化协调
    @Published var lastSavedAt: Date?

    // UndoManager 由 MainView.onAppear 注入（生命周期 = app 期间）
    var undoManager: UndoManager?

    // MARK: - 依赖
    private let cardService = CardService.shared
    // v1.3.0：weak 持有 statsState（避免循环引用，AppDelegate 才是 owner）
    // 引用链：AppDelegate → EditorState → data（弱持）statsState
    private weak var statsState: StatsState?
    weak var alert: EditorAlertState?
    weak var listState: ListState?
    private lazy var typeChangeService = CardTypeChangeService(data: self)
    private lazy var lifecycleService = CardLifecycleService(data: self, statsState: statsState)

    init(statsState: StatsState, listState: ListState, alert: EditorAlertState) {
        self.statsState = statsState
        self.listState = listState
        self.alert = alert
    }

    // MARK: - 业务方法（数据态）

    /// 开一张新卡 — 同步设置草稿状态，不生成 UUID
    /// v1.3.4 PATCH：无 UUID 草稿语义，避免空卡立即进入回收站
    func startNewCard(type: CardType = .free) {
        currentCard = nil
        currentCardType = type
        currentCardTags = []
        alert?.saveError = nil
        withAnimation(KaJiAnimation.modeSwitch) {
            listState?.listFilter = nil
            listState?.refreshFilteredCards()
            listState?.rightPaneMode = .editor
        }
    }

    /// 当用户在无 UUID 草稿上开始输入时，立即生成 UUID 并创建 Card。
    /// 只在 currentCard == nil 时调用；已有卡时不操作。
    func ensureCurrentCardID() {
        guard currentCard == nil else { return }
        do {
            let id = try CardIDGenerator.next()
            currentCard = Card.new(type: currentCardType, id: id, title: "", tags: currentCardTags, fields: [:])
        } catch {
            alert?.saveError = "无法生成卡片编码：\(error.localizedDescription)"
        }
    }

    /// 列表行点击后把指定卡片加载进编辑器
    func openCard(_ card: Card) {
        currentCard = card
        currentCardType = card.cardType
        currentCardTags = card.tags
        // v1.2.9 T3：selection 同步
        selectedCardID = card.id
    }

    func requestCardTypeChange(to type: CardType) {
        typeChangeService.requestChange(to: type)
    }

    func confirmPendingCardTypeChange() {
        typeChangeService.confirmPendingChange()
    }

    /// Undo 入口：恢复卡片类型和字段（由 CardTypeChangeService 注册）
    func undoCardTypeChange(to type: CardType, fields: [CardField]) {
        typeChangeService.undoChange(to: type, fields: fields)
    }

    /// 复制当前卡片全部内容到剪贴板（Markdown 格式）
    func copyAllContentToPasteboard() {
        guard let card = currentCard else { return }
        cardService.copyAllContentToPasteboard(for: card)
    }

    // MARK: - 自动保存

    /// 任何字段被编辑都会调用，800ms debounce 后真正落库
    func saveImmediately() {
        cardService.debounceSave { [weak self] in
            self?.persistCurrentCard()
        }
    }

    /// 强制立即落库（失焦 / 退出 / ⌘S 时调用）
    func flushSave() {
        cardService.flushSave { [weak self] in
            self?.persistCurrentCard()
        }
    }

    private func persistCurrentCard() {
        // v1.3.4 PATCH：无 UUID 草稿直接丢弃，不写库
        guard var c = currentCard else { return }
        c.type = currentCardType.rawValue
        c.tags = currentCardTags

        // v1.3.4 PATCH：空卡自动删除 — 已持久化且内容 trim 全空 → 走软删（带 undo 注册）
        // 未持久化的空卡直接丢弃，避免无意义记录进入主库/回收站
        if c.isEmpty {
            if hasBeenPersisted(c) {
                softDeleteCard(c)
            }
            return
        }

        // 3500 字符截断（title + 所有字段名 + 字段值 + 标签）
        if ContentLimit.isOverLimit(card: c) {
            c = ContentLimit.truncate(c)
        }

        // 截断结果立即同步回 UI，避免后台写盘完成后再覆盖 currentCard（H-2）
        currentCard = c

        // 写盘 + 重建统计放到后台队列，主线程只刷新 @Published（H-2）
        Task {
            do {
                try await cardService.persist(card: c)
                lastSavedAt = Date()
                alert?.saveError = nil
                let stats = try await cardService.refreshStats()
                // v1.3.0：weak statsState 加 guard let
                statsState?.update(with: stats)
                listState?.refreshFilteredCards()
            } catch {
                alert?.saveError = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// v1.3.4 PATCH：判断卡是否已在 DB 中（用于空卡自动删除的 hasBeenPersisted 守卫）
    /// 用 1 次单 row 查询（< 1ms），避免新空卡自循环入回收站。
    private func hasBeenPersisted(_ card: Card) -> Bool {
        (try? CardRepository.shared.card(id: card.id)) != nil
    }

    // MARK: - 卡片生命周期

    /// 列表行/菜单删除入口：带 UndoManager 注册
    func softDeleteCard(_ card: Card) {
        // v1.2.9 T3：删除时清空 selection（避免已删卡留在高亮态）
        if selectedCardID == card.id {
            selectedCardID = nil
        }
        // 如果删的是当前编辑的卡，同步清空 currentCard 并回到无 UUID 自由卡草稿
        if currentCard?.id == card.id {
            currentCard = nil
            currentCardType = .free
            currentCardTags = []
        }
        lifecycleService.softDelete(card)
    }

    /// v1.2.9 T5 入口：仅传 id 的软删除（CardListRow context menu 用）
    /// service 内部从 SQLite 读完整 Card，再走原 softDelete 流程
    func softDeleteCardByID(_ id: String) {
        guard let card = try? CardRepository.shared.card(id: id) else { return }
        softDeleteCard(card)
    }

    /// Undo 入口：从回收站恢复卡片
    func restoreCard(_ card: Card) {
        // v1.2.9 T3：恢复时 selection 不变（仅 deletedAt 变化，不影响列表行可见性）
        lifecycleService.restore(card)
    }
}
