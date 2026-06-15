//
//  CardRepository.swift
//  KaJi
//
//  唯一入口 — UI 层所有 cards 读写都走这里。
//
//  设计原则：
//  1. .md 是 source of truth — 每次写入先写 .md，再更新 SQLite
//  2. 单事务包裹"主表 + 字段表 + 标签关联"（R-03：写盘不是真原子但尽量紧凑）
//  3. 读路径：直接查 SQLite（.md 不需要每次读）
//  4. 搜索统一走内存缓存 filter（StatsState.cachedCards），不再维护 FTS5 索引
//  5. 回收站：del(card) 改 deletedAt，不删 .md；restore 改回 null；purge 真删
//

import Foundation
@preconcurrency import GRDB

final class CardRepository: @unchecked Sendable {
    fileprivate let db: AppDatabase
    static let shared = CardRepository()

    private init(db: AppDatabase = .shared) { self.db = db }

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

    // MARK: - 更新

    /// 更新一张卡（.md + SQLite）
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
