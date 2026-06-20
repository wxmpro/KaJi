//
//  CardFileIO.swift
//  KaJi
//
//  .md 文件派生视图（derived view）— 按 V1 草稿 + 数据库设计文档。
//
//  文件路径：~/Library/Application Support/KaJi/cards/<id>.md
//  文件格式：Markdown + YAML frontmatter（方便人读、git 同步、备份）
//  写盘策略：SQLite 事务提交成功后，再写 .md；.md 写入失败不破坏主数据一致性
//  写盘方式：先写 .tmp 再 rename（原子替换）
//

import Foundation
import os

struct CardFileIO {
    private static let log = Logger(subsystem: "com.kaji.app", category: "cardfileio")

    // 已知字段名集合从 CardType.allCases 动态构建，
    // 与 renderMarkdown 输出的中文字段名永久同步
    private static let knownFieldNames: Set<String> = {
        var names: Set<String> = ["title", "tags"]
        for type in CardType.allCases {
            names.formUnion(type.fields)
        }
        return names
    }()

    // MARK: - 路径

    /// 数据根目录
    static func dataRoot() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DatabaseError.applicationSupportUnavailable
        }
        return appSupport.appendingPathComponent("KaJi", isDirectory: true)
    }

    /// cards/ 目录根（每张卡一个 .md，按 YYYY/MM/ 归档：cards/YYYY/MM/<id>.md）
    static func cardsDir() throws -> URL {
        try dataRoot().appendingPathComponent("cards", isDirectory: true)
    }

    /// 从 17 位 ID 解析年月（YYYY-MM）
    /// - 17 位 ID 格式：YYYYMMDDHHMMSSsss（前 8 位 = 日期，前 14 位 = 时间到秒）
    /// - 年取前 4 位，月份取 5-6 位
    private static func yearMonth(from id: String) throws -> String {
        guard CardIDGenerator.isValid(id) else {
            throw MarkdownError.invalidID(id: id)
        }
        return String(id.prefix(4)) + "-" + String(id.dropFirst(4).prefix(2))
    }

    /// 单卡 .md 路径：cards/YYYY-MM/<id>.md
    static func fileURL(for id: String) throws -> URL {
        let ym = try yearMonth(from: id)
        return try cardsDir()
            .appendingPathComponent(ym, isDirectory: true)
            .appendingPathComponent("\(id).md")
    }

    /// 列出 cards 目录下所有 .md 文件的 id（用于启动对账）
    /// 递归扫 cards/YYYY/MM/*.md
    static func listAllIDs() throws -> Set<String> {
        let dir = try cardsDir()
        try ensureDirectory(dir)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var ids = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            ids.insert(url.deletingPathExtension().lastPathComponent)
        }
        return ids
    }

    // MARK: - 写盘

    /// 写卡到 .md（原子：tmp → rename）
    /// - Returns: 最终 .md URL
    @discardableResult
    static func write(_ card: Card) throws -> URL {
        let url = try fileURL(for: card.id)
        try ensureDirectory(url.deletingLastPathComponent())
        let content = renderMarkdown(card)
        let tmp = url.appendingPathExtension("tmp")
        do {
            try content.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return url
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            log.error(".md 写入失败 (\(card.id)): \(error.localizedDescription, privacy: .public)")
            throw MarkdownError.writeFailed(cardId: card.id, underlying: error)
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
    /// 所有字符串字段强制双引号（避免 true/123/null 解析歧义）
    static func renderMarkdown(_ card: Card) -> String {
        var out = "---\n"
        out += "id: \(quote(card.id))\n"
        out += "mdVersion: \(card.mdVersion)\n"                      // 数字不加引号
        out += "type: \(quote(card.type))\n"
        out += "title: \(quote(card.title))\n"
        out += "createdAt: \(iso8601(card.createdAt))\n"            // 时间保留 ISO8601
        out += "updatedAt: \(iso8601(card.updatedAt))\n"
        if let d = card.deletedAt {
            out += "deletedAt: \(iso8601(d))\n"
        }
        if !card.tags.isEmpty {
            out += "tags: [\(card.tags.map { quote($0) }.joined(separator: ", "))]\n"
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
    /// 入口先 normalize（去 BOM + CRLF → LF），避免跨平台 .md 解析失败
    static func parseMarkdown(_ rawText: String) throws -> Card {
        let text = normalize(rawText)
        var currentLine = 1   // 用于错误信息定位（normalize 后行号保持一致）

        // frontmatter 边界
        let headerPrefix = "---\n"
        guard text.hasPrefix(headerPrefix) else {
            throw MarkdownError.missingFrontmatter
        }

        let bodyStartIndex = text.index(text.startIndex, offsetBy: headerPrefix.utf16.count)
        guard let separatorRange = text[bodyStartIndex...].range(of: "\n---\n") else {
            throw MarkdownError.missingFrontmatterEnd(line: currentLine)
        }

        let fmStart = bodyStartIndex
        let fmEnd = separatorRange.lowerBound
        let fm = String(text[fmStart..<fmEnd])
        let body = String(text[separatorRange.upperBound...])

        // frontmatter 行解析
        var id = ""; var type = ""; var title = ""
        var createdAt = Date(); var updatedAt = Date()
        var deletedAt: Date?
        var tags: [String] = []
        var mdVersion: Int64 = 0
        for line in fm.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            currentLine += 1
            if let v = l.stripping(prefix: "id:") { id = unquote(v.trimmingCharacters(in: .whitespaces)) }
            else if let v = l.stripping(prefix: "mdVersion:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                mdVersion = Int64(trimmed) ?? 0
            }
            else if let v = l.stripping(prefix: "type:") { type = unquote(v.trimmingCharacters(in: .whitespaces)) }
            else if let v = l.stripping(prefix: "title:") { title = unquote(v.trimmingCharacters(in: .whitespaces)) }
            else if let v = l.stripping(prefix: "createdAt:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if let d = parseISO(trimmed) { createdAt = d }
                else { log.warning("无法解析 createdAt: \(trimmed, privacy: .public)") }
            }
            else if let v = l.stripping(prefix: "updatedAt:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if let d = parseISO(trimmed) { updatedAt = d }
                else { log.warning("无法解析 updatedAt: \(trimmed, privacy: .public)") }
            }
            else if let v = l.stripping(prefix: "deletedAt:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if let d = parseISO(trimmed) { deletedAt = d }
                else { log.warning("无法解析 deletedAt: \(trimmed, privacy: .public)") }
            }
            else if let v = l.stripping(prefix: "tags:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    let inner = String(trimmed.dropFirst().dropLast())
                    tags = inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }

        // body 解析 — 按 "## 字段名" 拆段，严格校验字段名合法性
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
            currentLine += 1
            if line.hasPrefix("## ") {
                let candidateName = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                // 严格校验 — 未知字段名抛错（不静默丢失内容）
                guard knownFieldNames.contains(candidateName) else {
                    throw MarkdownError.unknownField(name: candidateName, line: currentLine)
                }
                flush()
                currentField = candidateName
            } else if line.hasPrefix("# ") {
                continue   // 标题行忽略（已在 frontmatter）
            } else if currentField != nil {
                currentValue.append(line)
            }
        }
        flush()

        return Card(
            id: id, type: type.isEmpty ? CardType.free.rawValue : type,
            title: title, tags: tags, fields: fields,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt,
            mdVersion: mdVersion
        )
    }

    // MARK: - 辅助

    private static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// 规范化文本 — 去 BOM + CRLF → LF + 行尾 trim trailing whitespace
    private static func normalize(_ text: String) -> String {
        var s = text
        // 去 BOM
        if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
        // CRLF → LF（含单独 CR → LF，覆盖老 Mac 风格）
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    private static func iso8601(_ d: Date) -> String {
        DateFormatting.string(d)
    }

    private static func parseISO(_ s: String) -> Date? {
        DateFormatting.parse(s)
    }

    /// 强制所有字符串加双引号（避免 true/123/null 解析歧义）
    /// JSON 风格转义：`\\` `"` `\n` `\t`
    private static func quote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            + "\""
    }

    /// 双引号包裹则去除（反向操作）
    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\"") && s.hasSuffix("\""), s.count >= 2 else {
            return s
        }
        let inner = String(s.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
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