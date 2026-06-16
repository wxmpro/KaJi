//
//  CardFileIO.swift
//  KaJi
//
//  .md 文件派生视图（derived view）— 按 V1 草稿 + 数据库设计文档。
//
//  - 文件路径：~/Library/Application Support/KaJi/cards/<id>.md
//  - 文件格式：Markdown + YAML frontmatter（方便人读、git 同步、备份）
//  - 写盘策略：SQLite 事务提交成功后，再写 .md；.md 写入失败不破坏主数据一致性
//  - 写盘方式：先写 .tmp 再 rename（原子替换）
//
//  单卡导出（PRD V2 #9）+ 批量导出也用同一格式。
//

import Foundation

struct CardFileIO {
    /// v1.2.9 S1 修复：定义结构化错误，替代 force unwrap
    enum CardFileIOError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "无法获取 Application Support 目录（沙盒/MDM 限制下可能触发）。"
            }
        }
    }

    // MARK: - 路径

    /// 数据根目录
    /// v1.2.9 S1 修复：原 `FileManager.default.urls(...).first!` 在极端情况
    /// （沙盒/MDM 异常）下会 crash。改为 throws，调用方可在 UI 层提示用户。
    static func dataRoot() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CardFileIOError.applicationSupportUnavailable
        }
        return appSupport.appendingPathComponent("KaJi", isDirectory: true)
    }

    /// cards/ 目录（每张卡一个 .md）
    /// v1.2.9 S1 修复：throws 版本
    static func cardsDir() throws -> URL {
        try dataRoot().appendingPathComponent("cards", isDirectory: true)
    }

    /// 单卡 .md 路径
    /// v1.2.9 S1 修复：throws 版本
    static func fileURL(for id: String) throws -> URL {
        try cardsDir().appendingPathComponent("\(id).md")
    }

    /// 列出 cards 目录下所有 .md 文件的 id（用于启动对账）
    static func listAllIDs() throws -> Set<String> {
        let dir = try cardsDir()
        try ensureDirectory(dir)
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return Set(urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        })
    }

    // MARK: - 写盘

    /// 写卡到 .md（原子：tmp → rename）
    /// - Returns: 最终 .md URL
    @discardableResult
    static func write(_ card: Card) throws -> URL {
        let dir = try cardsDir()
        try ensureDirectory(dir)
        let url = try fileURL(for: card.id)
        let content = renderMarkdown(card)
        let tmp = url.appendingPathExtension("tmp")
        do {
            try content.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return url
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// 从 .md 读卡（用于 SQLite 重建 / 备份恢复）
    static func read(id: String) throws -> Card? {
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseMarkdown(text)
    }

    /// 删卡（移到回收站时不删 .md；彻底删时调用）
    static func delete(id: String) throws {
        let url = try fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 渲染：Card → Markdown

    /// 渲染为 Markdown + YAML frontmatter
    static func renderMarkdown(_ card: Card) -> String {
        var out = "---\n"
        out += "id: \(card.id)\n"
        out += "type: \(card.type)\n"
        out += "title: \(yamlEscape(card.title))\n"
        out += "createdAt: \(iso8601(card.createdAt))\n"
        out += "updatedAt: \(iso8601(card.updatedAt))\n"
        if let d = card.deletedAt {
            out += "deletedAt: \(iso8601(d))\n"
        }
        if !card.tags.isEmpty {
            out += "tags: [\(card.tags.map { yamlEscape($0) }.joined(separator: ", "))]\n"
        }
        out += "---\n\n"
        out += "# \(card.title.isEmpty ? "（无标题）" : card.title)\n\n"
        for f in card.orderedFields {
            out += "## \(f.fieldName)\n\n\(f.fieldValue.isEmpty ? "（空）" : f.fieldValue)\n\n"
        }
        return out
    }

    // MARK: - 解析：Markdown → Card

    /// 解析 frontmatter + Markdown body
    static func parseMarkdown(_ text: String) throws -> Card {
        // 只匹配文件开头的 `---\n` 和第一个 `\n---\n` 作为 frontmatter 边界，
        // 避免用户 body 中的水平分隔线被误当作 frontmatter 结束。
        let headerPrefix = "---\n"
        guard text.hasPrefix(headerPrefix) else {
            throw NSError(domain: "CardFileIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "无 frontmatter"])
        }

        let bodyStartIndex = text.index(text.startIndex, offsetBy: headerPrefix.utf16.count)
        guard let separatorRange = text[bodyStartIndex...].range(of: "\n---\n") else {
            throw NSError(domain: "CardFileIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "无 frontmatter 结束标记"])
        }

        let fmStart = bodyStartIndex
        let fmEnd = separatorRange.lowerBound
        let fm = String(text[fmStart..<fmEnd])
        let body = String(text[separatorRange.upperBound...])

        // 简单 YAML 行解析（够用即可）
        var id = ""; var type = ""; var title = ""
        var createdAt = Date(); var updatedAt = Date()
        var deletedAt: Date?
        var tags: [String] = []
        for line in fm.split(separator: "\n") {
            let l = String(line)
            if let v = l.stripping(prefix: "id:") { id = v.trimmingCharacters(in: .whitespaces) }
            else if let v = l.stripping(prefix: "type:") { type = v.trimmingCharacters(in: .whitespaces) }
            else if let v = l.stripping(prefix: "title:") { title = yamlUnescape(v.trimmingCharacters(in: .whitespaces)) }
            else if let v = l.stripping(prefix: "createdAt:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if let d = parseISO(trimmed) { createdAt = d } else { print("[KaJi.CardFileIO] 无法解析 createdAt: \(trimmed)") }
            }
            else if let v = l.stripping(prefix: "updatedAt:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if let d = parseISO(trimmed) { updatedAt = d } else { print("[KaJi.CardFileIO] 无法解析 updatedAt: \(trimmed)") }
            }
            else if let v = l.stripping(prefix: "deletedAt:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if let d = parseISO(trimmed) { deletedAt = d } else { print("[KaJi.CardFileIO] 无法解析 deletedAt: \(trimmed)") }
            }
            else if let v = l.stripping(prefix: "tags:") {
                // 简单 [a, b, c] 解析
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    let inner = String(trimmed.dropFirst().dropLast())
                    tags = inner.split(separator: ",").map { yamlUnescape($0.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }

        // body 解析 — 按 "## 字段名" 拆段
        var fields: [CardField] = []
        let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var currentField: String?
        var currentValue: [String] = []
        var order = 0
        func flush() {
            if let f = currentField {
                let val = currentValue.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                fields.append(CardField(cardId: id, fieldName: f, fieldValue: val, fieldOrder: order))
                order += 1
            }
            currentValue = []
        }
        for line in bodyLines {
            if line.hasPrefix("## ") {
                flush()
                currentField = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# ") {
                // 标题行 — 忽略（已在 frontmatter）
                continue
            } else if currentField != nil {
                currentValue.append(line)
            }
        }
        flush()

        return Card(
            id: id, type: type.isEmpty ? CardType.free.rawValue : type,
            title: title, tags: tags, fields: fields,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }

    // MARK: - 辅助

    private static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // ISO8601DateFormatter 线程安全（Apple 文档），缓存避免每次写盘重复创建
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso8601(_ d: Date) -> String {
        Self.isoFormatter.string(from: d)
    }

    private static func parseISO(_ s: String) -> Date? {
        // 优化（v1.3.0 P0-2）：复用上面的 `isoFormatter` 静态缓存，避免每次解析
        // 都 new 一个 ISO8601DateFormatter。reconcile 期间每个 .md 的 frontmatter
        // 解析会调 4-5 次 parseISO，1k+ 卡库时启动期累计可达 ~700ms。
        // ISO8601DateFormatter 在 Apple 文档中标为线程安全（immutable），单线程内
        // 反复 date(from:) 安全。第一次失败（字符串无 fractional seconds）才 new fallback。
        if let d = isoFormatter.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func yamlEscape(_ s: String) -> String {
        // 简单转义：含特殊字符用双引号包
        if s.contains(where: { ":\"#&*!|>%@`".contains($0) || $0.isNewline }) {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }

    private static func yamlUnescape(_ s: String) -> String {
        if s.hasPrefix("\"") && s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return s
    }
}

// MARK: - String helper

private extension String {
    /// "key: value" -> "value"（不区分大小写；只剥一次）
    func stripping(prefix key: String) -> String? {
        let lower = self.lowercased()
        let kLower = key.lowercased()
        guard lower.hasPrefix(kLower) else { return nil }
        let rest = self.dropFirst(key.count)
        return rest.first == " " ? String(rest.dropFirst()) : String(rest)
    }
}
