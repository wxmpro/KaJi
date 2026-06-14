//
//  AppState.swift
//  KaJi
//
//  全局应用状态（ObservableObject）。
//  集中管理：当前卡、侧栏折叠、当前屏、in-memory 警告。
//  UI 层只跟 AppState 交互；不直接动 CardRepository。
//
//  v7.0.1：屏 1 / 屏 3 都用「currentCardDraft」单 textarea 模式；
//  字段是从 draft 解析出来的（标题独占第一行 / 余下进 type.fields[0]）。
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    // MARK: - 当前态
    @Published var currentCard: Card?           // 屏 1 编辑中 / 屏 3 详情
    @Published var currentCardDraft: String     // 屏 1 / 屏 3 composer textarea 内容
    @Published var currentCardType: CardType    // 当前卡类型（屏 1 可改；屏 3 锁定）
    @Published var currentCardTags: [String]    // 当前卡的标签

    // 屏状态机
    enum Screen { case composer, list, detail }
    @Published var screen: Screen = .composer

    // 侧栏
    @Published var sidebarCollapsed: Bool = false
    @Published var sidebarWidth: CGFloat = 240   // 侧栏宽度（可拖拽 180-400）
    @Published var sidebarColumnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - 侧栏显隐

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarColumnVisibility = (sidebarColumnVisibility == .all) ? .detailOnly : .all
            sidebarCollapsed = (sidebarColumnVisibility != .all)
        }
    }

    // 数据层告警
    @Published var isInMemoryDB: Bool = false
    @Published var saveError: String?
    @Published var lastSavedAt: Date?

    // 3500 字符超限提示
    @Published var charCount: Int = 0
    @Published var charLimitWarning: String?

    // 搜索
    @Published var searchKeyword: String = ""
    @Published var isSearchActive: Bool = false

    // 列表筛选
    @Published var filterType: CardType?
    @Published var filterTags: [String] = []

    // 回收站
    @Published var showingTrash: Bool = false

    // 设置
    @Published var showingSettings: Bool = false

    // 卡片类型切换确认
    @Published var showingTypeChangeAlert: Bool = false
    @Published var pendingCardType: CardType? = nil

    // MARK: - 右栏模式（v8.0.0：两栏 + 右栏动态切换）
    // .editor = 当前编辑的卡（SingleEditor）
    // .list   = 卡片列表（CardListView），由侧栏类型/标签/回收站触发
    enum RightPaneMode: Equatable {
        case editor
        case list
    }
    @Published var rightPaneMode: RightPaneMode = .editor

    // 列表筛选来源
    enum ListFilter: Equatable {
        case type(CardType)
        case tag(String)
        case trash
        case all
        case search(String)
    }
    @Published var listFilter: ListFilter? = nil

    // 切到列表前「正在编辑」的卡 id；点「← 返回」时恢复回 currentCard
    @Published var pendingReturnCard: Card? = nil

    // 导航历史栈（v8.1.0：列表内 back/forward）
    // pastCards: 倒序，最近的在 index 0
    // futureCards: 同上
    @Published var pastCards: [Card] = []
    @Published var futureCards: [Card] = []

    var canGoBack: Bool { !pastCards.isEmpty }
    var canGoForward: Bool { !futureCards.isEmpty }

    // 列表筛选对应的展示标题（用于顶部条）
    var listFilterTitle: String {
        switch listFilter {
        case .type(let t): return t.rawValue
        case .tag(let s):  return "#\(s)"
        case .trash:       return "回收站"
        case .all:         return "全部卡片"
        case .search(let s): return "搜索：\(s)"
        case .none:        return ""
        }
    }

    // 侧栏统计缓存：避免每次 UI 渲染都读库
    @Published private(set) var cachedTypeCounts: [CardType: Int] = [:]
    @Published private(set) var cachedTagCounts: [(String, Int)] = []

    // 卡片全量缓存：避免切换侧栏 filter 时反复读库
    @Published private(set) var cachedCards: [Card] = []

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 仓库引用
    let repository = CardRepository.shared

    init() {
        // 检查 DB 状态
        isInMemoryDB = AppDatabase.shared.isInMemory
        // 启动时跑清理
        try? repository.bootstrap()
        // 默认新建自由卡（不在 init 内调方法，inline 写）
        do {
            let existing = (try? AppDatabase.shared.allIDs()) ?? []
            let id = (try? CardIDGenerator.next(existing: existing)) ?? "00000000000000000"
            currentCard = Card.new(type: .free, id: id, title: "", tags: [], fields: [:])
            currentCardDraft = ""
            currentCardType = .free
            currentCardTags = []
        }

        // 预计算侧栏统计
        rebuildStats()
    }

    // MARK: - 屏 1: 新建 / 编辑

    /// 开一张新卡（屏 1 用）— 给定类型，默认自由卡
    /// 调用后自动切回编辑器模式，清空列表筛选和历史栈。
    func startNewCard(type: CardType = .free) {
        do {
            let existing = try AppDatabase.shared.allIDs()
            let id = try CardIDGenerator.next(existing: existing)
            currentCard = Card.new(type: type, id: id, title: "", tags: [], fields: [:])
            currentCardDraft = ""
            currentCardType = type
            currentCardTags = []
            saveError = nil

            // 无论从列表还是其他状态触发，都回到编辑器第一屏
            pendingReturnCard = nil
            pastCards = []
            futureCards = []
            listFilter = nil
            rightPaneMode = .editor
        } catch {
            saveError = "无法生成新卡编码：\(error.localizedDescription)"
        }
    }

    /// 加载已有卡进 composer（屏 3 → 屏 1 复用）
    func loadIntoComposer(_ card: Card) {
        currentCard = card
        currentCardType = card.cardType
        currentCardTags = card.tags
        // 把 title + fields 拼成 composer textarea 的初始内容
        // 第一行 = title；下面 = 第一个字段值
        var draft = card.title
        if let firstField = card.fields.sorted(by: { $0.fieldOrder < $1.fieldOrder }).first {
            if !firstField.fieldValue.isEmpty {
                draft += "\n\n" + firstField.fieldValue
            }
        }
        currentCardDraft = draft
    }

    /// 当前卡片是否已有内容（用于判断能否直接切换卡片类型）
    var currentCardHasContent: Bool {
        guard let card = currentCard else { return false }
        if !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return card.fields.contains {
            !$0.fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 用户请求切换卡片类型：有内容时弹出确认，无内容时直接切换
    func requestCardTypeChange(to type: CardType) {
        guard type != currentCardType else { return }
        if currentCardHasContent {
            pendingCardType = type
            showingTypeChangeAlert = true
        } else {
            applyCardTypeChange(to: type)
        }
    }

    /// 确认切换：清空字段并按新类型重建结构
    func confirmPendingCardTypeChange() {
        guard let type = pendingCardType else { return }
        applyCardTypeChange(to: type)
        pendingCardType = nil
    }

    private func applyCardTypeChange(to type: CardType) {
        currentCardType = type
        if var card = currentCard {
            card.type = type.rawValue
            card.fields = type.fields.enumerated().map { idx, name in
                CardField(cardId: card.id, fieldName: name, fieldValue: "", fieldOrder: idx)
            }
            // 标题保留，因为标题是通用字段
            currentCard = card
            saveImmediately()
        }
    }

    /// 复制当前卡片全部内容到剪贴板（Markdown 格式）
    func copyAllContentToPasteboard() {
        guard let card = currentCard else { return }
        var lines: [String] = []
        lines.append("## \(card.cardType.rawValue)")
        lines.append("")
        lines.append("**标题：** \(card.title)")
        for field in card.orderedFields {
            lines.append("")
            lines.append("**\(field.fieldName)：** \(field.fieldValue)")
        }
        lines.append("")
        lines.append("**唯一编码：** \(card.displayID)")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - 自动保存

    private var saveWorkItem: DispatchWorkItem?
    private static let saveDebounceInterval: TimeInterval = 0.8

    /// 任何字段被编辑都会调用，800ms debounce 后真正落库
    func saveImmediately() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistCurrentCard()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceInterval, execute: work)
    }

    /// 强制立即落库（失焦 / 退出 / ⌘S 时调用）
    func flushSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persistCurrentCard()
    }

    private func persistCurrentCard() {
        guard var c = currentCard else { return }
        c.type = currentCardType.rawValue
        c.tags = currentCardTags
        c.updatedAt = Date()

        // 3500 字符检测（title + 所有字段名 + 字段值 + 标签）
        charCount = ContentLimit.count(card: c)
        if ContentLimit.isOverLimit(card: c) {
            c = ContentLimit.truncate(c)
            charLimitWarning = "卡片内容超过 3500 字符上限，已截断到 \(ContentLimit.maxChars) 字符"
        } else {
            charLimitWarning = nil
        }

        do {
            let saved = try repository.update(card: c)
            currentCard = saved
            lastSavedAt = Date()
            saveError = nil
            rebuildStats()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 自动取首字段前 30 字（PRD V2 #2: 用户未输入标题时）
    private func extractTitleFromDraft() -> String {
        let firstNonEmpty = currentCardDraft
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return String(firstNonEmpty.prefix(ContentLimit.maxTitleChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 屏 1 模式：title 独占第一行，下面的非空内容堆到第一个非 title 字段里
    private func extractFieldsFromDraft(type: CardType, draft: String, title: String) -> [CardField] {
        let lines = draft.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let titleLine = title
        let body = lines
            .drop { $0 != titleLine && !$0.isEmpty ? false : true }
            .dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 第一个字段放全部正文，其他字段留空
        return type.fields.enumerated().map { idx, name in
            let value: String = (idx == 0) ? body : ""
            return CardField(cardId: currentCard?.id ?? "", fieldName: name, fieldValue: value, fieldOrder: idx)
        }
    }

    // MARK: - 列表

    /// 拉所有卡（含回收站过滤）— 优先走缓存，不直接读库
    func allCards(includeDeleted: Bool = false) -> [Card] {
        includeDeleted ? cachedCards : cachedCards.filter { $0.deletedAt == nil }
    }

    /// 搜索 — 走缓存
    func search(_ keyword: String) -> [Card] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return allCards() }
        return cachedCards.filter { card in
            card.title.localizedCaseInsensitiveContains(kw)
                || card.tags.contains { $0.localizedCaseInsensitiveContains(kw) }
                || card.fields.contains { $0.fieldValue.localizedCaseInsensitiveContains(kw) }
        }
    }

    /// 按类型统计卡片数
    func cardsCount(of type: CardType) -> Int {
        cachedTypeCounts[type, default: 0]
    }

    /// 标签使用统计（按数量倒序）
    func tagCounts() -> [(String, Int)] {
        cachedTagCounts
    }

    /// 重新计算并缓存侧栏统计（数据变化时调用）
    func rebuildStats() {
        let cards = (try? repository.allCards(includeDeleted: true)) ?? []
        cachedCards = cards

        var typeDict: [CardType: Int] = [:]
        for type in CardType.allCases {
            typeDict[type] = cards.filter { $0.cardType == type && $0.deletedAt == nil }.count
        }
        cachedTypeCounts = typeDict

        var tagDict: [String: Int] = [:]
        for card in cards where card.deletedAt == nil {
            for tag in card.tags {
                tagDict[tag, default: 0] += 1
            }
        }
        cachedTagCounts = tagDict.sorted { $0.value > $1.value }
    }

    // MARK: - 侧栏宽度持久化

    func loadSidebarWidth() {
        let w = UserDefaults.standard.double(forKey: "kaji.sidebarWidth")
        if w > 0 { sidebarWidth = CGFloat(w) }
    }

    func saveSidebarWidth() {
        UserDefaults.standard.set(Double(sidebarWidth), forKey: "kaji.sidebarWidth")
    }

    // MARK: - 顶栏用
    var lastSavedAtLabel: String? {
        guard let savedAt = lastSavedAt else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "已保存 · \(f.string(from: savedAt))"
    }

    // MARK: - 列表模式切换

    /// 进入列表模式（侧栏点击类型/标签/回收站时调用）
    func showList(_ filter: ListFilter) {
        pendingReturnCard = currentCard   // 记住「我刚才在编辑哪张」
        listFilter = filter
        rightPaneMode = .list
    }

    /// 退出列表模式，回到 pendingReturnCard
    func returnToEditor() {
        if let card = pendingReturnCard {
            // 重新加载（防止列表里编辑过别的卡，pendingReturnCard 已不是最新）
            if let fresh = (try? repository.card(id: card.id)) ?? Optional<Card>.none {
                currentCard = fresh
                currentCardType = fresh.cardType
                currentCardTags = fresh.tags
            } else {
                currentCard = card
                currentCardType = card.cardType
                currentCardTags = card.tags
            }
        }
        pendingReturnCard = nil
        listFilter = nil
        pastCards = []
        futureCards = []
        rightPaneMode = .editor
    }

    /// 列表行点击 → 进入编辑（同时压入历史栈）
    func openCardFromList(_ card: Card) {
        if let cur = currentCard {
            pastCards.insert(cur, at: 0)
        }
        futureCards = []   // 新分支清空 forward
        currentCard = card
        currentCardType = card.cardType
        currentCardTags = card.tags
        withAnimation(.easeInOut(duration: 0.18)) {
            rightPaneMode = .editor
        }
    }

    /// ← 返回
    func goBack() {
        guard let prev = pastCards.first else { return }
        pastCards.removeFirst()
        if let cur = currentCard {
            futureCards.insert(cur, at: 0)
        }
        loadCardIntoEditor(prev)
    }

    /// → 前进
    func goForward() {
        guard let next = futureCards.first else { return }
        futureCards.removeFirst()
        if let cur = currentCard {
            pastCards.insert(cur, at: 0)
        }
        loadCardIntoEditor(next)
    }

    private func loadCardIntoEditor(_ card: Card) {
        if let fresh = (try? repository.card(id: card.id)) ?? Optional<Card>.none {
            currentCard = fresh
            currentCardType = fresh.cardType
            currentCardTags = fresh.tags
        } else {
            currentCard = card
            currentCardType = card.cardType
            currentCardTags = card.tags
        }
    }

    /// 当前筛选条件下的卡片（按 updatedAt 倒序）
    func filteredCards() -> [Card] {
        let cards: [Card]
        switch listFilter {
        case .type(let t):
            cards = cachedCards.filter { $0.cardType == t && $0.deletedAt == nil }
        case .tag(let s):
            cards = cachedCards.filter { $0.tags.contains(s) && $0.deletedAt == nil }
        case .trash:
            cards = cachedCards.filter { $0.deletedAt != nil }
        case .all:
            cards = cachedCards.filter { $0.deletedAt == nil }
        case .search(let keyword):
            let kw = keyword.trimmingCharacters(in: .whitespaces)
            cards = kw.isEmpty
                ? []
                : cachedCards.filter { card in
                    card.title.localizedCaseInsensitiveContains(kw)
                        || card.tags.contains { $0.localizedCaseInsensitiveContains(kw) }
                        || card.fields.contains { $0.fieldValue.localizedCaseInsensitiveContains(kw) }
                }
        case .none:
            cards = []
        }
        return cards.sorted { $0.updatedAt > $1.updatedAt }
    }
}
