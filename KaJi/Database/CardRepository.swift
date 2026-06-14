//
//  CardRepository.swift
//  KaJi
//
//  唯一入口 — UI 层所有 cards 读写都走这里。
//
//  设计原则：
//  1. .md 是 source of truth — 每次写入先写 .md，再更新 SQLite
//  2. 单事务包裹"主表 + 字段表 + 标签关联 + FTS 索引"（R-03：写盘不是真原子但尽量紧凑）
//  3. 读路径：直接查 SQLite（.md 不需要每次读）
//  4. 全文搜索走 FTS5（unicode61）
//  5. 回收站：del(card) 改 deletedAt，不删 .md；restore 改回 null；purge 真删
//

import Foundation
import GRDB

final class CardRepository: @unchecked Sendable {
    fileprivate let db: AppDatabase
    static let shared = CardRepository()

    private init(db: AppDatabase = .shared) { self.db = db }

    // MARK: - 创建

    /// 创建新卡（同时写 .md 和 SQLite）
    func create(card: Card) throws -> Card {
        var c = card
        // 3500 字截断（写盘前）
        if ContentLimit.isOverLimit(card: c) {
            c = ContentLimit.truncate(c)
        }
        // 写 .md
        let mdURL = try CardFileIO.write(c)
        // 写 SQLite
        try db.dbWriter.write { grdb in
            // cards
            var cardRec = CardRecord(
                id: c.id, type: c.type, title: c.title,
                createdAt: iso8601(c.createdAt), updatedAt: iso8601(c.updatedAt),
                deletedAt: c.deletedAt.map(iso8601),
                filePath: mdURL.path, fileMtime: nil, fileHash: nil, fileSize: 0
            )
            try cardRec.insert(grdb)
            // cardFields
            for f in c.fields {
                var fieldRec = CardFieldRecord(
                    cardId: f.cardId, fieldName: f.fieldName,
                    fieldValue: f.fieldValue, fieldOrder: f.fieldOrder
                )
                try fieldRec.insert(grdb)
            }
            // tags + cardTags
            for tag in c.tags {
                let tagRec = try ensureTag(named: tag, in: grdb)
                try CardTagRecord(cardId: c.id, tagId: tagRec.id!).insert(grdb)
            }
            // FTS
            try indexFTS(card: c, in: grdb)
        }
        return c
    }

    // MARK: - 读取

    /// 按 id 读一张卡（SQLite）
    func card(id: String) throws -> Card? {
        try db.dbWriter.read { grdb in
            guard let rec = try CardRecord.fetchOne(grdb, key: id) else { return nil }
            return try hydrate(record: rec, in: grdb)
        }
    }

    /// 全部卡（默认按 createdAt DESC；可过滤 deleted）
    func allCards(includeDeleted: Bool = false) throws -> [Card] {
        try db.dbWriter.read { grdb in
            let sql = includeDeleted
                ? "SELECT * FROM cards ORDER BY createdAt DESC"
                : "SELECT * FROM cards WHERE deletedAt IS NULL ORDER BY createdAt DESC"
            let recs = try CardRecord.fetchAll(grdb, sql: sql)
            return try recs.map { try hydrate(record: $0, in: grdb) }
        }
    }

    /// 回收站卡（deletedAt 非空）
    func trashCards() throws -> [Card] {
        try db.dbWriter.read { grdb in
            let recs = try CardRecord.fetchAll(grdb, sql: """
                SELECT * FROM cards WHERE deletedAt IS NOT NULL
                ORDER BY deletedAt DESC
                """)
            return try recs.map { try hydrate(record: $0, in: grdb) }
        }
    }

    // MARK: - 更新

    /// 更新一张卡（.md + SQLite + FTS）
    func update(card: Card) throws -> Card {
        var c = card
        if ContentLimit.isOverLimit(card: c) {
            c = ContentLimit.truncate(c)
        }
        c.updatedAt = Date()
        // 写 .md
        let mdURL = try CardFileIO.write(c)
        // 写 SQLite
        try db.dbWriter.write { grdb in
            // cards
            try CardRecord(
                id: c.id, type: c.type, title: c.title,
                createdAt: iso8601(c.createdAt), updatedAt: iso8601(c.updatedAt),
                deletedAt: c.deletedAt.map(iso8601),
                filePath: mdURL.path, fileMtime: nil, fileHash: nil, fileSize: 0
            ).update(grdb)
            // cardFields — 先删后插
            try CardFieldRecord
                .filter(Column("cardId") == c.id)
                .deleteAll(grdb)
            for f in c.fields {
                var fieldRec = CardFieldRecord(
                    cardId: f.cardId, fieldName: f.fieldName,
                    fieldValue: f.fieldValue, fieldOrder: f.fieldOrder
                )
                try fieldRec.insert(grdb)
            }
            // cardTags — 先删后插
            try CardTagRecord
                .filter(Column("cardId") == c.id)
                .deleteAll(grdb)
            for tag in c.tags {
                let tagRec = try ensureTag(named: tag, in: grdb)
                try CardTagRecord(cardId: c.id, tagId: tagRec.id!).insert(grdb)
            }
            // FTS — 删旧插新
            try grdb.execute(sql: "DELETE FROM cardsFts WHERE id = ?", arguments: [c.id])
            try indexFTS(card: c, in: grdb)
        }
        return c
    }

    // MARK: - 删除 / 回收站

    /// 移到回收站（改 deletedAt；不删 .md）
    func softDelete(id: String) throws {
        let now = iso8601(Date())
        try db.dbWriter.write { grdb in
            try grdb.execute(sql: "UPDATE cards SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                             arguments: [now, now, id])
        }
    }

    /// 从回收站恢复（deletedAt = NULL）
    func restore(id: String) throws {
        let now = iso8601(Date())
        try db.dbWriter.write { grdb in
            try grdb.execute(sql: "UPDATE cards SET deletedAt = NULL, updatedAt = ? WHERE id = ?",
                             arguments: [now, id])
        }
    }

    /// 彻底删除（不经过 30 天）
    func hardDelete(id: String) throws {
        try db.dbWriter.write { grdb in
            try grdb.execute(sql: "DELETE FROM cards WHERE id = ?", arguments: [id])
        }
        try CardFileIO.delete(id: id)
    }

    // MARK: - 全文搜索

    /// 关键词搜索（标题 + 字段值）
    /// 走 FTS5（unicode61；中文按字切分 — R-04 升级 trigram 待跟进）
    func search(keyword: String, includeDeleted: Bool = false) throws -> [Card] {
        guard !keyword.isEmpty else { return try allCards(includeDeleted: includeDeleted) }
        let escaped = keyword  // FTS5 quote: "  → ""
        return try db.dbWriter.read { grdb in
            // 用 prefix match * 让"心流"匹配"心流状态"
            let pattern = "\"\(escaped)\"*"
            let sql = """
                SELECT c.* FROM cards c
                JOIN cardsFts fts ON fts.id = c.id
                WHERE cardsFts MATCH ?
                \(includeDeleted ? "" : "AND c.deletedAt IS NULL")
                ORDER BY c.createdAt DESC
                """
            let recs = try CardRecord.fetchAll(grdb, sql: sql, arguments: [pattern])
            return try recs.map { try hydrate(record: $0, in: grdb) }
        }
    }

    // MARK: - 标签

    /// 全部标签（按 useCount DESC；用 COUNT(cardTags)）
    func allTags() throws -> [(name: String, useCount: Int)] {
        try db.dbWriter.read { grdb in
            let rows = try Row.fetchAll(grdb, sql: """
                SELECT t.name, COUNT(ct.cardId) as cnt
                FROM tags t
                LEFT JOIN cardTags ct ON ct.tagId = t.id
                LEFT JOIN cards c ON c.id = ct.cardId AND c.deletedAt IS NULL
                GROUP BY t.id
                ORDER BY cnt DESC, t.name ASC
                """)
            return rows.map { (name: $0["name"] as String, useCount: $0["cnt"] as Int) }
        }
    }

    // MARK: - 内部辅助

    /// 内部：把 record → Card（同时把 cardFields / tags 拉出来）
    private func hydrate(record rec: CardRecord, in grdb: Database) throws -> Card {
        let fields = try CardFieldRecord
            .filter(Column("cardId") == rec.id)
            .order(Column("fieldOrder"))
            .fetchAll(grdb)
            .map { CardField(cardId: $0.cardId, fieldName: $0.fieldName, fieldValue: $0.fieldValue, fieldOrder: $0.fieldOrder) }
        let tagRows = try Row.fetchAll(grdb, sql: """
            SELECT t.name FROM tags t
            JOIN cardTags ct ON ct.tagId = t.id
            WHERE ct.cardId = ?
            ORDER BY t.name ASC
            """, arguments: [rec.id])
        let tags = tagRows.map { $0["name"] as String }

        return Card(
            id: rec.id, type: rec.type, title: rec.title,
            tags: tags, fields: fields,
            createdAt: parseISO(rec.createdAt) ?? Date(),
            updatedAt: parseISO(rec.updatedAt) ?? Date(),
            deletedAt: rec.deletedAt.flatMap(parseISO)
        )
    }

    /// 内部：建/取标签
    private func ensureTag(named name: String, in grdb: Database) throws -> TagRecord {
        if let existing = try TagRecord.filter(Column("name") == name).fetchOne(grdb) {
            return existing
        }
        var rec = TagRecord(id: nil, name: name)
        try rec.insert(grdb)
        return rec
    }

    /// 内部：写入 FTS
    private func indexFTS(card: Card, in grdb: Database) throws {
        let blob = card.orderedFields.map { $0.fieldValue }.joined(separator: " ")
        try grdb.execute(sql: """
            INSERT INTO cardsFts (id, title, fieldValue) VALUES (?, ?, ?)
            """, arguments: [card.id, card.title, blob])
    }

    // MARK: - 公共辅助

    /// 启动时跑一次：清理 30 天前回收站
    func bootstrap() throws {
        try db.purgeOldTrash()
    }

    // MARK: - 公共辅助

    /// DB 是否处于 in-memory 模式（fallback）— UI 层可以展示警告
    var isInMemory: Bool { db.isInMemory }

    // ISO8601 helpers — 用 nonisolated(unsafe) 让 Swift 6 并发不报警
    // 风险：ISO8601DateFormatter 本身线程安全（Apple 文档说线程安全）
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private func iso8601(_ d: Date) -> String { Self.isoFormatter.string(from: d) }
    private func parseISO(_ s: String) -> Date? {
        if let d = Self.isoFormatter.date(from: s) { return d }
        let simple = ISO8601DateFormatter()
        simple.formatOptions = [.withInternetDateTime]
        return simple.date(from: s)
    }
}
