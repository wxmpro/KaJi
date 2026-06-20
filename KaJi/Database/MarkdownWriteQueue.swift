//
//  MarkdownWriteQueue.swift
//  KaJi
//
//  .md 派生视图写入队列（actor 串行化）。
//
//  设计原则：
//  - 串行化所有 .md 写入（actor 隔离），彻底消除 race
//  - 相同 id 自动合并最新版本（去重）
//  - 失败追踪与写入解耦（MarkdownFailureTracker 独立）
//  - 提供 flush() / retryFailures() API
//

import Foundation

/// .md 写入串行化队列
/// - 写入路径：Repository.save/softDelete/restore → enqueue → actor 内部串行处理
/// - 重试路径：reconcile 启动期 → retryFailures() 主动重试 .md_failures 标记
/// - 退出路径：applicationShouldTerminate → flush() 同步等待所有 pending 写完
actor MarkdownWriteQueue {
    static let shared = MarkdownWriteQueue()

    /// 待写入队列：key = card.id, value = 最新 Card 版本
    private var pending: [String: Card] = [:]
    private var isProcessing = false

    // MARK: - 公共 API

    /// 入队写 .md
    /// - 相同 id 自动合并为最新版本
    /// - 自动启动处理器（actor 内部串行，单次仅 1 个处理循环）
    func enqueue(_ card: Card) {
        pending[card.id] = card
        ensureProcessing()
    }

    /// 同步等待所有 pending 写完（应用退出 / 失焦 / reconcile 收尾）
    func flush() async {
        while !pending.isEmpty {
            await processOnce()
        }
    }

    /// 主动重试所有 .md_failures 标记
    /// - reconcile 启动期调用
    /// - 从 SQLite 读最新 card 入队（覆盖内存中可能更旧的 card）
    /// - card 已彻底删除时清理无主 failure 标记
    func retryFailures() async {
        let failureIDs = MarkdownFailureTracker.listFailures()
        guard !failureIDs.isEmpty else { return }
        for id in failureIDs {
            if let card = try? CardRepository.shared.card(id: id) {
                pending[id] = card
            } else {
                // card 已彻底删除，清理无主标记
                MarkdownFailureTracker.clearFailure(id: id)
            }
        }
        if !pending.isEmpty {
            ensureProcessing()
            await flush()
        }
    }

    // MARK: - 内部处理

    /// 确保单次处理循环已启动（避免并发多个循环）
    private func ensureProcessing() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { [weak self] in
            await self?.drain()
            await self?.markDone()
        }
    }

    /// 持续处理直到 pending 为空
    private func drain() async {
        while !pending.isEmpty {
            await processOnce()
        }
    }

    private func markDone() {
        isProcessing = false
    }

    /// 处理队列首条：写 .md；成功清 failure，失败 markFailed
    private func processOnce() async {
        guard let (id, card) = pending.first else { return }
        pending.removeValue(forKey: id)
        do {
            _ = try CardFileIO.write(card)
            MarkdownFailureTracker.clearFailure(id: id)
        } catch {
            MarkdownFailureTracker.markFailed(id: id, error: error)
        }
    }
}
