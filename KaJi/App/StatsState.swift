//
//  StatsState.swift
//  KaJi
//
//  数据缓存与统计状态。
//  负责侧栏统计、全量卡片缓存，以及统计刷新调度。
//

import SwiftUI

@MainActor
final class StatsState: ObservableObject {
    private let cardService = CardService.shared

    // 侧栏统计缓存：避免每次 UI 渲染都读库
    @Published private(set) var cachedTypeCounts: [CardType: Int] = [:]
    @Published private(set) var cachedTagCounts: [(String, Int)] = []

    // 卡片全量缓存：避免切换侧栏 filter 时反复读库
    @Published private(set) var cachedCards: [Card] = []

    /// 拉所有卡（含回收站过滤）— 优先走缓存，不直接读库
    func allCards(includeDeleted: Bool = false) -> [Card] {
        includeDeleted ? cachedCards : cachedCards.filter { $0.deletedAt == nil }
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
    /// v1.3.0 P0-5 修复：每次赋值前用 `!=` 守门，值相等时**不**触发 objectWillChange，
    /// 避免 List / SidebarView 在数据无变化时被无谓重建。
    /// 触发场景举例：编辑标题时 typeCounts / tagCounts 没变，但旧实现仍触发级联刷新，
    /// 导致 CardListView.body 重算 + ForEach 重建；新实现短路后整条链不发。
    /// 注：[(String, Int)] 元组数组在 Swift 6 下不能直接走 Equatable 协议，
    ///     用 zip + `==` 元素比较做 O(N) 短路。([Card] / [CardType: Int] 的 `!=` 可用，
    ///     是 Array/Dictionary 标准 Equatable)
    func update(with stats: (
        cards: [Card],
        typeCounts: [CardType: Int],
        tagCounts: [(String, Int)]
    )) {
        if cachedCards != stats.cards { cachedCards = stats.cards }
        if cachedTypeCounts != stats.typeCounts { cachedTypeCounts = stats.typeCounts }
        let tagSame = cachedTagCounts.count == stats.tagCounts.count
            && zip(cachedTagCounts, stats.tagCounts).allSatisfy { $0 == $1 }
        if !tagSame { cachedTagCounts = stats.tagCounts }
    }

    /// 重新计算并缓存侧栏统计（数据变化时调用）
    /// - Parameter onError: 统计刷新失败时的回调；调用方可通过它把错误写回 EditorState.saveError。
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
