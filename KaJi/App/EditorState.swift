//
//  EditorState.swift
//  KaJi
//
//  编辑器与当前卡片状态。
//  负责当前卡片、类型切换弹窗、搜索、自动保存、剪贴板、 UndoManager。
//

import SwiftUI
import AppKit

@MainActor
final class EditorState: ObservableObject {
    // MARK: - 依赖
    private let cardService = CardService.shared
    private let persistence = PersistenceCoordinator()
    private let statsState: StatsState
    private let listState: ListState
    private lazy var typeChangeService = CardTypeChangeService(editorState: self)
    private lazy var lifecycleService = CardLifecycleService(editorState: self, statsState: statsState)

    // MARK: - 当前态
    @Published var currentCard: Card?           // 屏 1 编辑中 / 屏 3 详情
    @Published var currentCardType: CardType = .free    // 当前卡类型
    @Published var currentCardTags: [String] = []       // 当前卡的标签

    // 侧栏
    @Published var sidebarColumnVisibility: NavigationSplitViewVisibility = .all

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarColumnVisibility = (sidebarColumnVisibility == .all) ? .detailOnly : .all
        }
    }

    // 数据层告警
    @Published var isInMemoryDB: Bool = false
    @Published var saveError: String?
    @Published var lastSavedAt: Date?

    // 搜索
    @Published var searchKeyword: String = ""
    @Published var isSearchActive: Bool = false

    // 卡片类型切换确认
    @Published var showingTypeChangeAlert: Bool = false
    @Published var pendingCardType: CardType? = nil

    /// UndoManager 由 SwiftUI 环境注入（MainView.onAppear 设置）
    var undoManager: UndoManager?

    init(statsState: StatsState, listState: ListState) {
        self.statsState = statsState
        self.listState = listState

        // 1. 先初始化所有 @Published 基本状态
        isInMemoryDB = AppDatabase.shared.isInMemory
        do {
            currentCard = try cardService.generateNewCard(type: .free)
            currentCardType = .free
            currentCardTags = []
        } catch {
            currentCard = nil
            currentCardType = .free
            currentCardTags = []
            saveError = "无法生成新卡编码：\(error.localizedDescription)"
        }

        // 2. 启动时跑清理 + 预计算侧栏统计：放到后台，避免 init 阻塞主线程（H-2）
        Task {
            do {
                try await cardService.bootstrap(retentionDays: SettingsService.trashRetentionDays)
                statsState.rebuildStats()
            } catch {
                saveError = "启动清理失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 屏 1: 新建 / 编辑

    /// 开一张新卡（屏 1 用）— 给定类型，默认自由卡
    func startNewCard(type: CardType = .free) {
        do {
            currentCard = try cardService.generateNewCard(type: type)
            currentCardType = type
            currentCardTags = []
            saveError = nil
            listState.listFilter = nil
            listState.refreshFilteredCards()
            listState.rightPaneMode = .editor
        } catch {
            saveError = "无法生成新卡编码：\(error.localizedDescription)"
        }
    }

    /// 列表行点击后把指定卡片加载进编辑器
    func openCard(_ card: Card) {
        currentCard = card
        currentCardType = card.cardType
        currentCardTags = card.tags
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
        persistence.debounce { [weak self] in
            self?.persistCurrentCard()
        }
    }

    /// 强制立即落库（失焦 / 退出 / ⌘S 时调用）
    func flushSave() {
        persistence.flush { [weak self] in
            self?.persistCurrentCard()
        }
    }

    private func persistCurrentCard() {
        guard var c = currentCard else { return }
        c.type = currentCardType.rawValue
        c.tags = currentCardTags

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
                saveError = nil
                let stats = try await cardService.refreshStats()
                statsState.update(with: stats)
                listState.refreshFilteredCards()
            } catch {
                saveError = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 卡片生命周期

    /// 列表行/菜单删除入口：带 UndoManager 注册
    func softDeleteCard(_ card: Card) {
        lifecycleService.softDelete(card)
    }

    /// Undo 入口：从回收站恢复卡片
    func restoreCard(_ card: Card) {
        lifecycleService.restore(card)
    }
}
