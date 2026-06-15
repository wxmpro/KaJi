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

    // MARK: - 路径

    /// 数据根目录
    static var dataRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KaJi", isDirectory: true)
    }

    /// cards/ 目录（每张卡一个 .md）
    static var cardsDir: URL {
        dataRoot.appendingPathComponent("cards", isDirectory: true)
    }

    /// 单卡 .md 路径
    static func fileURL(for id: String) -> URL {
        cardsDir.appendingPathComponent("\(id).md")
    }

    /// 列出 cards 目录下所有 .md 文件的 id（用于启动对账）
    static func listAllIDs() throws -> Set<String> {
        try ensureDirectory(cardsDir)
        let urls = try FileManager.default.contentsOfDirectory(
            at: cardsDir,
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
        try ensureDirectory(cardsDir)
        let url = fileURL(for: card.id)
        let content = renderMarkdown(card)
        let tmp = url.appendingPathExtension("tmp")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        // rename 覆盖（原子；同卷下 mv 是 POSIX atomic）
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return url
    }

    /// 从 .md 读卡（用于 SQLite 重建 / 备份恢复）
    static func read(id: String) throws -> Card? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseMarkdown(text)
    }

    /// 删卡（移到回收站时不删 .md；彻底删时调用）
    static func delete(id: String) throws {
        let url = fileURL(for: id)
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
        // 拆 frontmatter 与 body
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count >= 2 else {
            throw NSError(domain: "CardFileIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "无 frontmatter"])
        }
        let fm = parts[0].replacingOccurrences(of: "---\n", with: "")
        let body = parts[1...].joined(separator: "\n---\n")

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
            else if let v = l.stripping(prefix: "createdAt:") { createdAt = parseISO(v.trimmingCharacters(in: .whitespaces)) ?? Date() }
            else if let v = l.stripping(prefix: "updatedAt:") { updatedAt = parseISO(v.trimmingCharacters(in: .whitespaces)) ?? Date() }
            else if let v = l.stripping(prefix: "deletedAt:") { deletedAt = parseISO(v.trimmingCharacters(in: .whitespaces)) }
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
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
