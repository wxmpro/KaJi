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
    private var updateObservers: [() -> Void] = []

    /// 添加更新观察者（Bug 9 修复：支持多个观察者，不再单点覆盖）
    func addUpdateObserver(_ observer: @escaping () -> Void) {
        updateObservers.append(observer)
    }

    /// 移除更新观察者
    func removeUpdateObserver(_ observer: @escaping () -> Void) {
        // 闭包无法直接比较，需要 caller 用 token 模式管理
        // 实际场景中 ListState 是 App 生命周期内单例，不需要移除
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
        for observer in updateObservers { observer() }
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
