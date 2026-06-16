//
//  CardService.swift
//  KaJi
//
//  卡片业务逻辑服务中心。
//  把旧 AppState 里混杂的仓库交互、后台持久化、统计计算、剪贴板等逻辑抽出来，
//  让 EditorState / ListState / StatsState 分别负责 UI 状态协调。
//

import Foundation
import AppKit

/// 卡片业务服务：所有与 CardRepository / 剪贴板 / ID 生成相关的操作入口。
/// 被 @unchecked Sendable 是因为内部持有 CardRepository（它本身已是 @unchecked Sendable），
/// 且所有后台任务都通过 Task.detached 显式切换队列，不泄露 isolation。
final class CardService: @unchecked Sendable {
    static let shared = CardService()

    private let repository: CardRepository

    private init(repository: CardRepository = .shared) {
        self.repository = repository
    }

    // MARK: - 启动与清理

    /// 启动清理：在后台 utility 队列执行回收站 purge
    /// - Parameter retentionDays: 回收站保留天数，由 SettingsService 提供
    func bootstrap(retentionDays: Int) async throws {
        let repo = repository
        try await Task.detached(priority: .utility) {
            try repo.bootstrap(retentionDays: retentionDays)
        }.value
    }

    // MARK: - 新卡

    /// 生成一张新卡（不写库）
    /// 异步原因：`AppDatabase.allIDs()` 是一次 SQLite 全表读，在 1k+ 卡片时
    /// 在主线程跑会肉眼可感卡顿。挪到 detached utility 队列后，UI 完全不阻塞。
    /// 调用方（EditorState.startNewCard / init）用 `Task { @MainActor in try await ... }` 包裹即可。
    func generateNewCard(type: CardType) async throws -> Card {
        let existing = try await Task.detached(priority: .userInitiated) {
            try AppDatabase.shared.allIDs()
        }.value
        let id = try CardIDGenerator.next(existing: existing)
        return Card.new(type: type, id: id, title: "", tags: [], fields: [:])
    }

    // MARK: - 持久化

    /// 写卡到 SQLite + .md：在后台 utility 队列执行
    /// SQLite 是强一致锚点；.md 是派生视图，写入失败会由启动对账修复
    func persist(card: Card) async throws {
        let repo = repository
        try await Task.detached(priority: .utility) {
            _ = try repo.save(card: card)
        }.value
    }

    // MARK: - 自动保存调度（v1.2.9 T2 E：从 PersistenceCoordinator 合并过来）
    // 用 DispatchWorkItem 在 main queue 做 debounce / flush；
    // service 是 @unchecked Sendable，但内部 state 只在 main queue 读写，
    // 跨线程访问需在 caller 端保证在 @MainActor 调用（EditorDataState 已是 @MainActor）。
    // @MainActor 标注：SettingsService.autoSaveInterval 是 @MainActor 隔离的，
    // 必须从 main actor 上下文调用才能读到值。

    @MainActor
    private var saveWorkItem: DispatchWorkItem?

    /// 防抖保存：取消上一个 pending 任务，延迟 interval 后执行
    @MainActor
    func debounceSave(action: @escaping () -> Void) {
        saveWorkItem?.cancel()
        let interval = SettingsService.autoSaveInterval
        let work = DispatchWorkItem { action() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// 立即落库：取消 pending 并立刻执行
    @MainActor
    func flushSave(action: @escaping () -> Void) {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        action()
    }

    // MARK: - 删除 / 恢复

    /// 移到回收站（同步执行：单条 SQLite UPDATE，足够快；Undo 注册前必须完成）
    func softDelete(id: String) throws {
        try repository.softDelete(id: id)
    }

    /// 从回收站恢复（同步执行）
    func restore(id: String) throws {
        try repository.restore(id: id)
    }

    // MARK: - 统计

    /// 读全量卡并计算侧栏统计（后台执行）
    func refreshStats() async throws -> (
        cards: [Card],
        typeCounts: [CardType: Int],
        tagCounts: [(String, Int)]
    ) {
        let repo = repository
        return try await Task.detached(priority: .utility) {
            let cards = try repo.allCards(includeDeleted: true)

            // v1.2.8 P1-2 修复：typeDict 计算 O(12N) → O(N)
            // 旧实现对 12 个 CardType 各做一次 cards.filter,每次 O(N),总 O(12N)
            // 新实现:Dictionary 预填 0 + 单次遍历所有 cards 累加,总 O(N)
            // 0 UI 风险,纯聚合逻辑,结果完全一致
            var typeDict: [CardType: Int] = Dictionary(
                uniqueKeysWithValues: CardType.allCases.map { ($0, 0) }
            )
            for card in cards where card.deletedAt == nil {
                typeDict[card.cardType, default: 0] += 1
            }

            var tagDict: [String: Int] = [:]
            for card in cards where card.deletedAt == nil {
                for tag in card.tags {
                    tagDict[tag, default: 0] += 1
                }
            }

            return (
                cards: cards,
                typeCounts: typeDict,
                tagCounts: tagDict.sorted { $0.value > $1.value }
            )
        }.value
    }

    // MARK: - 列表筛选

    /// 根据筛选条件从缓存的全量卡片中计算应显示的卡片列表
    func filteredCards(from cards: [Card], matching filter: ListFilter?) -> [Card] {
        let result: [Card]
        switch filter {
        case .type(let type):
            result = cards.filter { $0.cardType == type && $0.deletedAt == nil }
        case .tag(let tag):
            result = cards.filter { $0.tags.contains(tag) && $0.deletedAt == nil }
        case .trash:
            result = cards.filter { $0.deletedAt != nil }
        case .all:
            result = cards.filter { $0.deletedAt == nil }
        case .search(let keyword):
            let kw = keyword.trimmingCharacters(in: .whitespaces)
            result = kw.isEmpty
                ? []
                : cards.filter { card in
                    card.deletedAt == nil
                        && (card.title.localizedCaseInsensitiveContains(kw)
                            || card.tags.contains { $0.localizedCaseInsensitiveContains(kw) }
                            || card.fields.contains { $0.fieldValue.localizedCaseInsensitiveContains(kw) })
                }
        case .none:
            result = []
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 剪贴板

    /// 复制当前卡片全部内容到剪贴板（Markdown 格式）
    func copyAllContentToPasteboard(for card: Card) {
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
}
