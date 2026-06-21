//
//  StatsState.swift
//  KaJi
//
//  数据缓存与统计状态。
//  负责侧栏统计、轻量卡片缓存（[CardSummary]），以及统计刷新调度。
//

import SwiftUI
import Combine

@Observable
@MainActor
final class StatsState {
    // MARK: - 依赖
    @ObservationIgnored
    private let cardService: CardService

    // MARK: - 更新回调（多观察者数组化，支持精确移除）
    @ObservationIgnored
    private var updateObservers: [UUID: () -> Void] = [:]

    /// 添加更新观察者，返回 token 用于精确移除
    @discardableResult
    func addUpdateObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        updateObservers[token] = observer
        return token
    }

    /// 移除更新观察者
    func removeUpdateObserver(token: UUID) {
        updateObservers.removeValue(forKey: token)
    }

    // MARK: - 侧栏统计缓存
    var cachedTypeCounts: [String: Int] = [:]
    var cachedTagCounts: [(String, Int)] = []

    // MARK: - 轻量卡片缓存
    var cachedSummaries: [CardSummary] = []

    /// 启动加载态。bootstrap 关键阶段 + 首屏统计加载完成前为 true，
    /// 列表/侧栏据此显示「正在加载卡片库...」，避免空白窗口被误认为卡死。
    var isBootstrapping: Bool = true

    init(cardService: CardService = .shared) {
        self.cardService = cardService
    }

    /// 拉所有卡（含回收站过滤）— 优先走缓存，不直接读库
    func allCards(includeDeleted: Bool = false) -> [CardSummary] {
        includeDeleted ? cachedSummaries : cachedSummaries.filter { $0.deletedAt == nil }
    }

    /// 按类型统计卡片数
    func cardsCount(of typeId: String) -> Int {
        cachedTypeCounts[typeId, default: 0]
    }

    /// 标签使用统计（按数量倒序）
    func tagCounts() -> [(String, Int)] {
        cachedTagCounts
    }

    /// 用外部已计算好的统计结果刷新缓存
    func update(with stats: (
        summaries: [CardSummary],
        typeCounts: [String: Int],
        tagCounts: [(String, Int)]
    )) {
        if cachedSummaries != stats.summaries {
            // 首次 sort 保证 sorted 不变式（updatedAt desc, id asc）
            // 之后 applyIncremental 维护不变式，filter 可跳过 sort
            cachedSummaries = stats.summaries.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
        }
        if cachedTypeCounts != stats.typeCounts { cachedTypeCounts = stats.typeCounts }
        let tagSame = cachedTagCounts.count == stats.tagCounts.count
            && zip(cachedTagCounts, stats.tagCounts).allSatisfy { $0 == $1 }
        if !tagSame { cachedTagCounts = stats.tagCounts }
        // 重建倒排索引
        cardService.updateSearchIndex(from: stats.summaries)
        // 关键：全量更新后让 filterCache 失效（summaries 整体替换，count 可能变也可能不变）
        cardService.invalidateFilterCache()
        // 触发所有观察者
        for observer in updateObservers.values { observer() }
    }

    /// 应用增量 diff，不重建整个缓存
    /// - changed: 新增/编辑后的卡 summary
    /// - removed: 软删除/彻底删除的卡 id 集合
    func applyIncremental(changed: [CardSummary], removed: Set<String> = []) {
        guard !changed.isEmpty || !removed.isEmpty else { return }

        var typeDiff: [String: Int] = [:]
        var tagDiff: [String: Int] = [:]

        // 1. 先根据当前缓存计算旧值 diff
        let oldByID = Dictionary(uniqueKeysWithValues: cachedSummaries.map { ($0.id, $0) })

        for id in removed {
            guard let old = oldByID[id] else { continue }
            if old.deletedAt == nil {
                typeDiff[old.type, default: 0] -= 1
                for tag in old.tags { tagDiff[tag, default: 0] -= 1 }
            }
        }

        for summary in changed {
            if let old = oldByID[summary.id] {
                // 旧值 -1（只计未删除的）
                if old.deletedAt == nil {
                    typeDiff[old.type, default: 0] -= 1
                    for tag in old.tags { tagDiff[tag, default: 0] -= 1 }
                }
            }
            // 新值 +1（只计未删除的）
            if summary.deletedAt == nil {
                typeDiff[summary.type, default: 0] += 1
                for tag in summary.tags { tagDiff[tag, default: 0] += 1 }
            }
        }

        // 2. 更新 cachedSummaries（增量调整，不再全量 sort）
        //    不变式：cachedSummaries 按 (updatedAt desc, id asc) 排序
        //    同 updatedAt 按 id 字典序，避免侧栏/列表重排

        // 2.1 先移除 removed
        for id in removed {
            if let idx = cachedSummaries.firstIndex(where: { $0.id == id }) {
                cachedSummaries.remove(at: idx)
            }
        }

        // 2.2 changed cards：移除旧的，二分查找插入位置，插入新的
        for newSummary in changed {
            if let idx = cachedSummaries.firstIndex(where: { $0.id == newSummary.id }) {
                cachedSummaries.remove(at: idx)
            }
            let insertIdx = Self.insertPosition(for: newSummary, in: cachedSummaries)
            cachedSummaries.insert(newSummary, at: insertIdx)
        }

        // 3. 应用 typeCounts diff
        for (typeId, delta) in typeDiff {
            let newValue = cachedTypeCounts[typeId, default: 0] + delta
            if newValue != 0 {
                cachedTypeCounts[typeId] = newValue
            } else {
                cachedTypeCounts.removeValue(forKey: typeId)
            }
        }

        // 4. 应用 tagCounts diff
        //    稳定排序 — 同 count 按 tag 名字典序，避免 applyIncremental
        //    反复触发时 Dictionary 迭代顺序无序导致同 count 标签随机跳动
        var tagDict = Dictionary(uniqueKeysWithValues: cachedTagCounts.map { ($0.0, $0.1) })
        for (tag, delta) in tagDiff {
            let newCount = (tagDict[tag] ?? 0) + delta
            if newCount > 0 {
                tagDict[tag] = newCount
            } else {
                tagDict.removeValue(forKey: tag)
            }
        }
        cachedTagCounts = tagDict
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { ($0.key, $0.value) }

        // 5. 增量同步倒排索引
        cardService.updateSearchIndex(from: cachedSummaries)

        // 6. 关键：增量更新后让 filterCache 失效（改卡 count 不变但 summary 字段变了，
        //    旧 cached result 会导致 UI 不显示新 tags / title / deletedAt — v1.7.4 P0）
        cardService.invalidateFilterCache()

        // 7. 触发观察者
        for observer in updateObservers.values { observer() }
    }

    /// 二分查找插入位置（按 updatedAt desc, id asc 排序的不变式）。
    /// O(log N)，配合 Array.insert(at:) 实现 O(log N + N) 增量调整。
    /// 返回第一个让 `summary` 应该排在 `array[i]` 之前的位置。
    private static func insertPosition(for summary: CardSummary, in array: [CardSummary]) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let midSummary = array[mid]
            if midSummary.updatedAt != summary.updatedAt {
                // desc 排序：updatedAt 大的排前面
                if summary.updatedAt > midSummary.updatedAt {
                    hi = mid
                } else {
                    lo = mid + 1
                }
            } else {
                // 同 updatedAt：按 id asc 排序
                if summary.id < midSummary.id {
                    hi = mid
                } else {
                    lo = mid + 1
                }
            }
        }
        return lo
    }

    /// 重新计算并缓存侧栏统计（数据变化时调用）
    /// - Parameter onError: 统计刷新失败时的回调
    func rebuildStats(onError: ((Error) -> Void)? = nil) {
        Task {
            do {
                let stats = try await cardService.refreshStats()
                update(with: stats)
            } catch {
                onError?(error)
            }
        }
    }
}
