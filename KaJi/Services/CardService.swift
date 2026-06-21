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

    /// 关键对账 —— 仅恢复「.md 有但 DB 没有」的卡，
    /// 影响首屏数据完整性，必须在首屏渲染前同步完成。开销极小。
    /// - Returns: ReconcileResult 包含恢复成功数、失败数、失败 ID 列表及首个错误
    func bootstrapCritical() async throws -> ReconcileResult {
        let repo = repository
        return try await Task.detached(priority: .userInitiated) {
            try await repo.reconcileCritical()
        }.value
    }

    /// 延迟对账 + 回收站清理 —— 纯 .md 派生修复 + purge，
    /// 不影响首屏 DB 数据，在首屏渲染后以低优先级后台执行。
    /// 含全量 mdVersion 扫描（已移出首屏关键路径）。
    func bootstrapDeferred(retentionDays: Int) async throws {
        let repo = repository
        try await Task.detached(priority: .utility) {
            try await repo.reconcileDeferred()
            try await repo.purgeOldTrashPublic(retentionDays: retentionDays)
        }.value
    }

    // MARK: - 新卡

    /// 生成一张新卡（不写库）
    /// CardIDGenerator 进程内单调 + DB UNIQUE 约束兜底跨进程。
    func generateNewCard(typeId: String) async throws -> Card {
        for _ in 1...10 {
            let candidateId: String
            do {
                candidateId = try CardIDGenerator.next()
            } catch {
                throw KaJiError.unknown(error)
            }
            // 校验 ID 格式（防御性：CardIDGenerator 内已保证）
            guard CardIDGenerator.isValid(candidateId) else {
                throw KaJiError.database(.idConflictExhausted(attempts: 10))
            }
            return Card.new(typeId: typeId, id: candidateId, title: "", tags: [], fields: [:])
        }
        throw KaJiError.database(.idConflictExhausted(attempts: 10))
    }

    // MARK: - 持久化

    /// 写卡到 SQLite + .md：在后台 utility 队列执行
    /// SQLite 是强一致锚点；.md 是派生视图，写入失败会由启动对账修复
    /// 捕获 idConflict 重试 — 跨进程场景下第二进程与第一进程撞 ID 时自动重生成
    /// 循环真正重试 10 次，并同步更新 CardField.cardId
    func persist(card: Card) async throws -> Card {
        let repo = repository
        var current = card
        for attempt in 1...10 {
            do {
                // 通过捕获列表 [current] 把当前卡快照传给 Task，避免闭包捕获 var
                return try await Task.detached(priority: .utility) { [current] in
                    try repo.save(card: current)
                }.value
            } catch DatabaseError.idConflict {
                // 用 continue 而非 return，让循环真正重试
                // 重试时同步刷新 fields 内每个 cardId 为 newId
                guard attempt < 10 else {
                    throw KaJiError.database(.idConflictExhausted(attempts: 10))
                }
                let newId: String
                do {
                    newId = try CardIDGenerator.next()
                } catch {
                    throw KaJiError.unknown(error)
                }
                current = Card(
                    id: newId,
                    type: current.type,
                    title: current.title,
                    tags: current.tags,
                    fields: current.fields.map {
                        CardField(cardId: newId, fieldName: $0.fieldName,
                                  fieldValue: $0.fieldValue, fieldOrder: $0.fieldOrder)
                    },
                    createdAt: current.createdAt,
                    updatedAt: current.updatedAt,
                    deletedAt: current.deletedAt,
                    mdVersion: current.mdVersion
                )
            }
        }
        throw KaJiError.database(.idConflictExhausted(attempts: 10))
    }

    // MARK: - 自动保存调度
    // 用 DispatchWorkItem 在 main queue 做 debounce / flush；
    // service 是 @unchecked Sendable，但内部 state 只在 main queue 读写。
    // @MainActor 标注：SettingsService.autoSaveInterval 是 @MainActor 隔离的。

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

    /// 取消 pending save（不执行 action）
    /// 场景：lifecycleService.softDelete/restore 之前需要取消 pending 的 debounce save
    /// （避免旧内容覆盖 deletedAt / 恢复后的字段）。
    @MainActor
    func cancelPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
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

    /// 把清空前的完整内容回写 + 软删除（单事务原子）
    /// 用于"逐步清空 → 回收站"场景，保证回收站显示清空前完整内容
    func softDeletePreservingContent(_ card: Card) throws {
        try repository.softDeletePreservingContent(card)
    }

    // MARK: - 统计

    /// 读全量卡并计算侧栏统计（后台执行）
    /// 3 路 SQL 聚合替代 hydrate 全库
    /// - typeCounts：GROUP BY type（O(N) → 一次 SQL）
    /// - tagCounts：JOIN cardTags + tags（O(M) → 一次 SQL）
    /// - summaries：轻量 [CardSummary]（不查 fields，内存 20MB → 1.2MB）
    /// 性能：10k 卡全库 ~10ms（vs 修复前 hydrate ~100ms）
    func refreshStats() async throws -> (
        summaries: [CardSummary],
        typeCounts: [String: Int],
        tagCounts: [(String, Int)]
    ) {
        let repo = repository
        return try await Task.detached(priority: .utility) {
            try repo.refreshStatsSQL()
        }.value
    }

    /// 增量统计 —— 只把 changed 卡转成 CardSummary，不扫全库
    /// 返回 changed summaries，由 StatsState.applyIncremental 负责合并到缓存并计算 diff
    func refreshStatsIncremental(changed: [Card]) async -> [CardSummary] {
        await Task.detached(priority: .utility) {
            changed.map { CardSummary(from: $0) }
        }.value
    }

    // MARK: - 列表筛选

    /// 搜索分支用 CardSearchIndex 倒排索引（O(命中)）替代 O(N) 线性匹配。
    /// 非搜索分支仍走 [CardSummary] 线性过滤（O(N) 但无 fields hydrate 成本）。
    private let searchIndex = CardSearchIndex()

    // MARK: - filter 分桶缓存
    /// 按 ListFilter 分桶缓存结果（.all / .type(t) / .tag(s) / .trash）。
    /// 命中条件：桶 key 匹配 + filterCacheVersion 未变 + summaries.count 未变。
    /// - summaries.count 防止增/删卡 stale（增删必然 count 变）
    /// - filterCacheVersion 防止**改卡** stale（改卡 count 不变，但 summary 字段变化；
    ///   StatsState.applyIncremental/update 末尾必须 invalidate）
    /// .search 不缓存（query 变化频繁；.none 也不缓存）。
    /// 主线程单线程访问（ListState.refreshFilteredCards 主线程调用），
    /// 不需要额外同步原语（与 searchIndex 保持一致）。
    private struct CachedFilter {
        let version: Int
        let count: Int
        let summaries: [CardSummary]
    }
    private var filterCache: [String: CachedFilter] = [:]
    private var filterCacheVersion: Int = 0

    /// 让所有桶缓存失效。StatsState.applyIncremental / update 末尾必须调，
    /// 否则改卡（count 不变但 summary 字段变化）会返回旧 cached 列表，
    /// 表现为 UI 不更新（v1.7.4 tags 不更新就是这种症状的子集）。
    func invalidateFilterCache() {
        filterCacheVersion &+= 1
    }

    func filteredCards(from summaries: [CardSummary], matching filter: ListFilter?) -> [CardSummary] {
        // 桶缓存命中：version 未变 + count 未变 + 桶 key 匹配 → O(1)
        if let cacheKey = Self.filterCacheKey(filter),
           let cached = filterCache[cacheKey],
           cached.version == filterCacheVersion,
           cached.count == summaries.count {
            return cached.summaries
        }

        // 重算 + 缓存
        let result = computeFilteredCards(from: summaries, matching: filter)
        if let cacheKey = Self.filterCacheKey(filter) {
            filterCache[cacheKey] = CachedFilter(
                version: filterCacheVersion,
                count: summaries.count,
                summaries: result
            )
        }
        return result
    }

    /// 实际计算 filter 结果（拆分出来便于与桶缓存逻辑隔离）
    /// 跳过 sort —— `summaries` 已 sorted（StatsState.update 首次 sort，
    /// applyIncremental 维护不变式），Swift `filter` 是稳定的，结果仍 sorted。
    private func computeFilteredCards(from summaries: [CardSummary], matching filter: ListFilter?) -> [CardSummary] {
        switch filter {
        case .type(let typeId):
            return summaries.filter { $0.type == typeId && $0.deletedAt == nil }
        case .tag(let tag):
            return summaries.filter { $0.tags.contains(tag) && $0.deletedAt == nil }
        case .trash:
            return summaries.filter { $0.deletedAt != nil }
        case .all:
            return summaries.filter { $0.deletedAt == nil }
        case .search(let keyword):
            let hits = searchIndex.search(keyword)
            return summaries.filter { hits.contains($0.id) && $0.deletedAt == nil }
        case .none:
            return []
        }
    }

    /// 桶缓存 key（用于按 filter 分桶）。nil 表示不缓存。
    private static func filterCacheKey(_ filter: ListFilter?) -> String? {
        switch filter {
        case .none: return nil       // 空 filter 不缓存
        case .all: return "all"
        case .type(let typeId): return "type:\(typeId)"
        case .tag(let s): return "tag:\(s)"
        case .trash: return "trash"
        case .search: return nil     // 搜索 query 变化频繁，不缓存
        }
    }

    /// 外部调用入口：刷新搜索索引（StatsState.update 触发，在主线程）
    /// 改增量同步（sync）替代全量 rebuild，未变化的卡跳过 tokenize
    func updateSearchIndex(from summaries: [CardSummary]) {
        searchIndex.sync(to: summaries)
    }

    // MARK: - 剪贴板

    /// 复制当前卡片全部内容到剪贴板（Markdown 格式）
    func copyAllContentToPasteboard(for card: Card) {
        var lines: [String] = []
        lines.append("## \(card.cardTypeDef.name)")
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
