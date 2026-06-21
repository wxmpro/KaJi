//
//  StatsState.swift
//  KaJi
//
//  数据缓存与统计状态。
//  负责侧栏统计、轻量卡片缓存（[CardSummary]），以及统计刷新调度。
//

import SwiftUI
import Combine
import GRDB

@Observable
@MainActor
final class StatsState {
    // MARK: - 依赖
    @ObservationIgnored
    private let cardService: CardService

    @ObservationIgnored
    private var statsObservationTask: Task<Void, Never>?

    // MARK: - 侧栏统计缓存
    var cachedTypeCounts: [String: Int] = [:]
    var cachedTagCounts: [(String, Int)] = []
    var cachedTrashCount: Int = 0

    /// 启动加载态。bootstrap 关键阶段 + 首屏统计加载完成前为 true，
    /// 列表/侧栏据此显示「正在加载卡片库...」，避免空白窗口被误认为卡死。
    var isBootstrapping: Bool = true

    init(cardService: CardService = .shared) {
        self.cardService = cardService
    }

    /// 回收站卡片数量
    func trashCount() -> Int {
        cachedTrashCount
    }

    /// 按类型统计卡片数
    func cardsCount(of typeId: String) -> Int {
        cachedTypeCounts[typeId, default: 0]
    }

    /// 标签使用统计（按数量倒序）
    func tagCounts() -> [(String, Int)] {
        cachedTagCounts
    }

    /// 启动侧栏统计的实时监听
    func startObservingStats() {
        statsObservationTask?.cancel()
        statsObservationTask = Task { @MainActor in
            let observation = ValueObservation.tracking { db in
                let typeCounts = try CardRepository.shared.fetchTypeCounts(db: db)
                let tagCounts = try CardRepository.shared.fetchTagCounts(db: db)
                let trashCount = try CardRepository.shared.fetchTrashCount(db: db)
                return (typeCounts, tagCounts, trashCount)
            }
            
            do {
                for try await (typeCounts, tagCounts, trashCount) in observation.values(in: AppDatabase.shared.dbWriter) {
                    if Task.isCancelled { break }
                    self.cachedTypeCounts = typeCounts
                    self.cachedTagCounts = tagCounts
                    self.cachedTrashCount = trashCount
                    self.isBootstrapping = false
                }
            } catch {
                // Handle DB errors if necessary
            }
        }
    }
}
