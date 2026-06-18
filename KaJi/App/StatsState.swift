//
//  StatsState.swift
//  KaJi
//
//  数据缓存与统计状态。
//  负责侧栏统计、轻量卡片缓存（v1.2.9 T5 改 [CardSummary]），以及统计刷新调度。
//
//  v1.2.9 T5 改造：cachedCards: [Card] → cachedSummaries: [CardSummary]（轻量）
//  v1.4.0：迁移到 @Observable
//

import SwiftUI
import Combine

@Observable
@MainActor
final class StatsState {
    // MARK: - 依赖
    @ObservationIgnored
    private let cardService: CardService

    // MARK: - 更新回调（v1.4.0：替代 @Observable 之前的 objectWillChange 订阅）
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
    var cachedTypeCounts: [CardType: Int] = [:]
    var cachedTagCounts: [(String, Int)] = []

    // MARK: - 轻量卡片缓存
    var cachedSummaries: [CardSummary] = []

    /// v1.6.0（批次5/群5）：启动加载态。bootstrap 关键阶段 + 首屏统计加载完成前为 true，
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
    func cardsCount(of type: CardType) -> Int {
        cachedTypeCounts[type, default: 0]
    }

    /// 标签使用统计（按数量倒序）
    func tagCounts() -> [(String, Int)] {
        cachedTagCounts
    }

    /// 用外部已计算好的统计结果刷新缓存
    func update(with stats: (
        summaries: [CardSummary],
        typeCounts: [CardType: Int],
        tagCounts: [(String, Int)]
    )) {
        if cachedSummaries != stats.summaries { cachedSummaries = stats.summaries }
        if cachedTypeCounts != stats.typeCounts { cachedTypeCounts = stats.typeCounts }
        let tagSame = cachedTagCounts.count == stats.tagCounts.count
            && zip(cachedTagCounts, stats.tagCounts).allSatisfy { $0 == $1 }
        if !tagSame { cachedTagCounts = stats.tagCounts }
        // 重建倒排索引
        cardService.updateSearchIndex(from: stats.summaries)
        // v1.4.0：触发所有观察者（Bug 9 修复）
        // v1.6.1：字典 values 遍历
        for observer in updateObservers.values { observer() }
    }

    /// v1.6.2 ARCH-2：应用增量 diff，不重建整个缓存
    /// - changed: 新增/编辑后的卡 summary
    /// - removed: 软删除/彻底删除的卡 id 集合
    func applyIncremental(changed: [CardSummary], removed: Set<String> = []) {
        guard !changed.isEmpty || !removed.isEmpty else { return }

        var typeDiff: [CardType: Int] = [:]
        var tagDiff: [String: Int] = [:]

        // 1. 先根据当前缓存计算旧值 diff
        let oldByID = Dictionary(uniqueKeysWithValues: cachedSummaries.map { ($0.id, $0) })

        for id in removed {
            guard let old = oldByID[id] else { continue }
            if old.deletedAt == nil {
                typeDiff[old.cardType, default: 0] -= 1
                for tag in old.tags { tagDiff[tag, default: 0] -= 1 }
            }
        }

        for summary in changed {
            if let old = oldByID[summary.id] {
                // 旧值 -1（只计未删除的）
                if old.deletedAt == nil {
                    typeDiff[old.cardType, default: 0] -= 1
                    for tag in old.tags { tagDiff[tag, default: 0] -= 1 }
                }
            }
            // 新值 +1（只计未删除的）
            if summary.deletedAt == nil {
                typeDiff[summary.cardType, default: 0] += 1
                for tag in summary.tags { tagDiff[tag, default: 0] += 1 }
            }
        }

        // 2. 更新 cachedSummaries
        var byID = oldByID
        for summary in changed { byID[summary.id] = summary }
        for id in removed { byID.removeValue(forKey: id) }
        cachedSummaries = Array(byID.values).sorted { $0.updatedAt > $1.updatedAt }

        // 3. 应用 typeCounts diff
        for (type, delta) in typeDiff {
            let newValue = cachedTypeCounts[type, default: 0] + delta
            if newValue != 0 {
                cachedTypeCounts[type] = newValue
            } else {
                cachedTypeCounts.removeValue(forKey: type)
            }
        }

        // 4. 应用 tagCounts diff
        var tagDict = Dictionary(uniqueKeysWithValues: cachedTagCounts.map { ($0.0, $0.1) })
        for (tag, delta) in tagDiff {
            let newCount = (tagDict[tag] ?? 0) + delta
            if newCount > 0 {
                tagDict[tag] = newCount
            } else {
                tagDict.removeValue(forKey: tag)
            }
        }
        cachedTagCounts = tagDict.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }

        // 5. 增量同步倒排索引
        cardService.updateSearchIndex(from: cachedSummaries)

        // 6. 触发观察者
        for observer in updateObservers.values { observer() }
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
