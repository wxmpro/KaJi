//
//  StatsState.swift
//  KaJi
//
//  数据缓存与统计状态。
//  负责侧栏统计、轻量卡片缓存（v1.2.9 T5 改 [CardSummary]），以及统计刷新调度。
//
//  v1.2.9 T5 改造：
//  - cachedCards: [Card] → cachedSummaries: [CardSummary]（内存 20MB → 1.2MB）
//  - update() 接收 summaries 类型，触发 searchIndex 重建
//

import SwiftUI

@MainActor
final class StatsState: ObservableObject {
    private let cardService = CardService.shared

    // 侧栏统计缓存：避免每次 UI 渲染都读库
    @Published private(set) var cachedTypeCounts: [CardType: Int] = [:]
    @Published private(set) var cachedTagCounts: [(String, Int)] = []

    // v1.2.9 T5：轻量缓存，替代 [Card]（不含 fields，按需懒加载）
    @Published private(set) var cachedSummaries: [CardSummary] = []

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
    /// v1.2.9 T5：value 相等时**不**触发 objectWillChange + 触发 searchIndex 重建
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
    }

    /// 重新计算并缓存侧栏统计（数据变化时调用）
    /// - Parameter onError: 统计刷新失败时的回调；调用方可通过它把错误写回 EditorAlertState.saveError。
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
