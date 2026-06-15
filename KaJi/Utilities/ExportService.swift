//
//  ExportService.swift
//  KaJi
//
//  md 导出：单卡 → .md 文件；批量 → 文件夹。
//  Phase 5: 单卡导出（⌘E）+ 批量导出（⌘⇧E）。
//  v1.0 简化版：复用 CardFileIO.renderMarkdown 直接写到 NSSavePanel 选择的位置。
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

    /// 在后台队列执行：读库 + 写所有 .md 文件
    private nonisolated static func exportAllCards(to url: URL) async throws -> Int {
        try await Task.detached(priority: .utility) {
            let cards = try CardRepository.shared.allCards(includeDeleted: false)
            for card in cards {
                let fileURL = url.appendingPathComponent("\(card.id).md")
                let md = CardFileIO.renderMarkdown(card)
                try md.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return cards.count
        }.value
    }
}
