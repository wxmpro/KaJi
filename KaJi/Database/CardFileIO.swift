//
//  CardFileIO.swift
//  KaJi
//
//  .md 文件派生视图（derived view）— 按 V1 草稿 + 数据库设计文档。
//
//  v1.3.2 彻底升级：
//  - parseMarkdown 入口 normalize（CRLF → LF + 去 BOM），解决跨平台 .md 解析失败
//  - renderMarkdown 所有字符串强制双引号（避免 true/123/null 歧义）
//  - 字段边界严格校验：未知字段名抛 MarkdownError.unknownField（不静默丢失）
//  - print 替换为 OSLog
//  - 删除冗余的 CardFileIOError（统一到 DatabaseError.applicationSupportUnavailable）
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

    // v1.6.1：已知字段名集合改为从 CardType.allCases 动态构建，
    // 与 renderMarkdown 输出的中文字段名永久同步，解决 render 写中文 / parse 认英文 100% 不匹配
    private static let knownFieldNames: Set<String> = {
        var names: Set<String> = ["title", "tags"]
        for type in CardType.allCases {
            names.formUnion(type.fields)
        }
        return names
    }()

    // MARK: - 路径

    /// 数据根目录
    /// v1.3.2：改抛 DatabaseError.applicationSupportUnavailable（统一错误类型）
    static func dataRoot() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DatabaseError.applicationSupportUnavailable
        }
        return appSupport.appendingPathComponent("KaJi", isDirectory: true)
    }

    /// cards/ 目录（每张卡一个 .md）
    static func cardsDir() throws -> URL {
        try dataRoot().appendingPathComponent("cards", isDirectory: true)
    }

    /// 单卡 .md 路径
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
    /// v1.3.2：所有字符串字段强制双引号（避免 true/123/null 解析歧义）
    static func renderMarkdown(_ card: Card) -> String {
        var out = "---\n"
        out += "id: \(quote(card.id))\n"                            // ★ 强引号
        // v1.3.0：把当前 SQLite 行的 mdVersion 写进 frontmatter 第一行
        out += "mdVersion: \(card.mdVersion)\n"                      // 数字不加引号
        out += "type: \(quote(card.type))\n"                         // ★ 强引号
        out += "title: \(quote(card.title))\n"                       // ★ 强引号
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
    /// v1.3.2：入口先 normalize（去 BOM + CRLF → LF），避免跨平台 .md 解析失败
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
                // ★ v1.3.2：严格校验 — 未知字段名抛错（不静默丢失内容）
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

    /// v1.3.2：规范化文本 — 去 BOM + CRLF → LF + 行尾 trim trailing whitespace
    private static func normalize(_ text: String) -> String {
        var s = text
        // 去 BOM
        if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
        // CRLF → LF（含单独 CR → LF，覆盖老 Mac 风格）
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    // ISO8601DateFormatter 线程安全（Apple 文档），缓存避免每次写盘重复创建
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoFormatterFallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso8601(_ d: Date) -> String {
        Self.isoFormatter.string(from: d)
    }

    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        return isoFormatterFallback.date(from: s)
    }

    /// v1.3.2：强制所有字符串加双引号（避免 true/123/null 解析歧义）
    /// JSON 风格转义：`\\` `"` `\n` `\t`
    private static func quote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            + "\""
    }

    /// v1.3.2：双引号包裹则去除（反向操作）
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