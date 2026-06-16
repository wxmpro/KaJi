//
//  MarkdownFailureTracker.swift
//  KaJi
//
//  v1.2.9 T4 引入：追踪 .md 派生视图写入失败。
//
//  - 失败标记：dataRoot/.md_failures/<id>.failure
//  - 标记内容：JSON { cardId, failedAt, reason, attemptCount }
//  - reconcile() 启动时扫一遍，尝试重写，修复后删除标记
//  - .md_failures 目录创建失败时 print 但不阻断主流程
//
//  边界 case：
//  - markFailed 内部全部 try-catch，fallback 到 print 日志
//  - listFailures 读目录失败时返回空数组
//  - failure 文件 JSON 损坏时 readRecord 抛错，markFailed 重新建（attemptCount 从 0 开始）
//

import Foundation
import os

enum MarkdownFailureTracker {
    private static let log = Logger(subsystem: "com.kaji.app", category: "markdown-failure")

    struct FailureRecord: Codable {
        let cardId: String
        let failedAt: Date
        let reason: String
        var attemptCount: Int
    }

    // MARK: - 路径

    /// .md_failures/ 目录
    static func failuresDir() throws -> URL {
        try CardFileIO.dataRoot().appendingPathComponent(".md_failures", isDirectory: true)
    }

    /// 单个 failure 标记文件路径
    static func failureFile(for id: String) throws -> URL {
        try failuresDir().appendingPathComponent("\(id).failure")
    }

    // MARK: - 写

    /// 写一个 failure 标记（id 已存在则 attemptCount++，否则新建）
    static func markFailed(id: String, error: Error) {
        do {
            let dir = try failuresDir()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = try failureFile(for: id)
            let existing = (try? readRecord(at: url))
            let record = FailureRecord(
                cardId: id,
                failedAt: Date(),
                reason: error.localizedDescription,
                attemptCount: (existing?.attemptCount ?? 0) + 1
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            // .md_failures 目录写失败：log 兜底，不阻断主流程
            log.error("markFailed 失败 (\(id, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 清理

    /// 删除 failure 标记（修复成功后调用）
    static func clearFailure(id: String) {
        guard let url = try? failureFile(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 列

    /// 列出所有 failure 标记对应的 cardId（reconcile 时用）
    static func listFailures() -> [String] {
        guard let dir = try? failuresDir(),
              FileManager.default.fileExists(atPath: dir.path) else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == "failure" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
    }

    // MARK: - 内部

    private static func readRecord(at url: URL) throws -> FailureRecord {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FailureRecord.self, from: data)
    }
}
