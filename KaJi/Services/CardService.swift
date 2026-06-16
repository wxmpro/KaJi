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
    /// v1.3.0：reconcile 改为 async，调用方需要 await
    func bootstrap(retentionDays: Int) async throws {
        let repo = repository
        try await Task.detached(priority: .utility) {
            try await repo.bootstrap(retentionDays: retentionDays)
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
    /// v1.2.9 T5 改造：3 路 SQL 聚合替代 hydrate 全库
    /// - typeCounts：GROUP BY type（O(N) → 一次 SQL）
    /// - tagCounts：JOIN cardTags + tags（O(M) → 一次 SQL）
    /// - summaries：轻量 [CardSummary]（不查 fields，内存 20MB → 1.2MB）
    /// 性能：10k 卡全库 ~10ms（vs 修复前 hydrate ~100ms）
    func refreshStats() async throws -> (
        summaries: [CardSummary],
        typeCounts: [CardType: Int],
        tagCounts: [(String, Int)]
    ) {
        let repo = repository
        return try await Task.detached(priority: .utility) {
            try repo.refreshStatsSQL()
        }.value
    }

    // MARK: - 列表筛选

    /// v1.2.9 T5 改造：输入 [CardSummary] 替代 [Card]
    /// 搜索分支用 CardSearchIndex 倒排索引（O(命中)）替代 O(N) 线性匹配。
    /// 非搜索分支仍走 [CardSummary] 线性过滤（O(N) 但无 fields hydrate 成本）。
    private let searchIndex = CardSearchIndex()

    func filteredCards(from summaries: [CardSummary], matching filter: ListFilter?) -> [CardSummary] {
        let result: [CardSummary]
        switch filter {
        case .type(let type):
            result = summaries.filter { $0.type == type.rawValue && $0.deletedAt == nil }
        case .tag(let tag):
            result = summaries.filter { $0.tags.contains(tag) && $0.deletedAt == nil }
        case .trash:
            result = summaries.filter { $0.deletedAt != nil }
        case .all:
            result = summaries.filter { $0.deletedAt == nil }
        case .search(let keyword):
            // v1.2.9 T5：用倒排索引命中
            let hits = searchIndex.search(keyword)
            result = summaries.filter { hits.contains($0.id) && $0.deletedAt == nil }
        case .none:
            result = []
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 外部调用入口：刷新搜索索引（StatsState.update 触发，在主线程）
    func updateSearchIndex(from summaries: [CardSummary]) {
        searchIndex.rebuild(from: summaries)
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
