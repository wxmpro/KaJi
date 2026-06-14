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

    // 侧栏统计缓存：避免每次 UI 渲染都读库
    @Published private(set) var cachedTypeCounts: [CardType: Int] = [:]
    @Published private(set) var cachedTagCounts: [(String, Int)] = []

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
    func startNewCard(type: CardType = .free) {
        do {
            let existing = try AppDatabase.shared.allIDs()
            let id = try CardIDGenerator.next(existing: existing)
            currentCard = Card.new(type: type, id: id, title: "", tags: [], fields: [:])
            currentCardDraft = ""
            currentCardType = type
            currentCardTags = []
            saveError = nil
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

    // MARK: - 自动保存

    /// 失焦 / ⌘S 时调用
    func saveImmediately() {
        guard let card = currentCard else { return }
        var c = card
        c.type = currentCardType.rawValue
        c.title = extractTitleFromDraft()
        c.tags = currentCardTags
        c.fields = extractFieldsFromDraft(type: currentCardType, draft: currentCardDraft, title: c.title)
        c.updatedAt = Date()

        // 3500 字符检测
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

    /// 拉所有卡（含回收站过滤）
    func allCards(includeDeleted: Bool = false) -> [Card] {
        (try? repository.allCards(includeDeleted: includeDeleted)) ?? []
    }

    /// 搜索
    func search(_ keyword: String) -> [Card] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return allCards() }
        return (try? repository.search(keyword: kw)) ?? []
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
        let cards = allCards()

        var typeDict: [CardType: Int] = [:]
        for type in CardType.allCases {
            typeDict[type] = cards.filter { $0.cardType == type }.count
        }
        cachedTypeCounts = typeDict

        var tagDict: [String: Int] = [:]
        for card in cards {
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
}
