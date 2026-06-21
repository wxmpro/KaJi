//
//  ExportService.swift
//  KaJi
//
//  md 导出：单卡 → .md 文件；批量 → 文件夹。
//  单卡导出（⌘E）+ 批量导出（⌘⇧E）。
//  复用 CardFileIO.renderMarkdown 直接写到 NSSavePanel 选择的位置。
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportService {

    /// 导出单张卡 — 用户选位置
    @MainActor
    static func exportCard(_ card: Card) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(card.id).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.title = "导出卡片"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let md = CardFileIO.renderMarkdown(card)
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// 批量导出所有卡 — 用户选文件夹
    /// 注意：选目录和弹窗必须在主线程；文件写入在后台 utility 队列，避免卡 UI。
    @MainActor
    static func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择导出文件夹"
        panel.message = "所有卡片将作为 .md 文件导出到此文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let count = try await exportAllCards(to: url)
                let alert = NSAlert()
                alert.messageText = "导出完成"
                alert.informativeText = "已导出 \(count) 张卡片到 \(url.lastPathComponent)"
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// 在 User-initiated 优先级后台队列执行：读库 + 写所有 .md 文件
    /// 文件名冲突时自动重命名（加 -1、-2…），避免覆盖用户目录中已有文件。
    /// 使用 .userInitiated 而非 .utility，避免导出过程中高优先级线程等待 DB 连接。
    private nonisolated static func exportAllCards(to url: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            let cards = try CardRepository.shared.allCards(includeDeleted: false)
            var writtenCount = 0
            for card in cards {
                let fileURL = Self.uniqueFileURL(in: url, baseName: card.id, extension: "md")
                let md = CardFileIO.renderMarkdown(card)
                try md.write(to: fileURL, atomically: true, encoding: .utf8)
                writtenCount += 1
            }
            return writtenCount
        }.value
    }

    private nonisolated static func uniqueFileURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        var index = 1
        while true {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
