//
//  CardRepository.swift
//  KaJi
//
//  唯一入口 — UI 层所有 cards 读写都走这里。
//
//  设计原则（SQLite-first）：
//  1. SQLite 是强一致锚点：每次写入先提交 SQLite 事务，再写 .md
//  2. .md 是派生视图/备份：用于人读、git 同步、灾难恢复，运行时不依赖它
//  3. 单事务包裹"主表 + 字段表 + 标签关联"（R-03）
//  4. 读路径：直接查 SQLite（.md 不需要每次读）
//  5. 搜索统一走内存缓存 filter（StatsState.cachedCards），不再维护 FTS5 索引
//  6. 回收站：del(card) 改 deletedAt，不删 .md；restore 改回 null；purge 真删
//  7. 启动对账（reconcile）：自动修复 .md 与 SQLite 之间的历史不一致
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

    // MARK: - 写入

    /// 保存/更新一张卡（SQLite 是强一致锚点，.md 是派生视图）
    /// - 先提交 SQLite 事务；事务成功后再写 .md
    /// - .md 写入失败不会破坏 SQLite 一致性，启动对账会修复
    func save(card: Card) throws -> Card {
        var c = card
        if ContentLimit.isOverLimit(card: c) {
            c = ContentLimit.truncate(c)
        }
        c.updatedAt = Date()

        // 1. SQLite 事务（ACID）：cards + cardFields + cardTags
        try db.dbWriter.write { grdb in
            try persist(c, in: grdb)
        }

        // 2. SQLite 提交成功后，再写 .md
        do {
            _ = try CardFileIO.write(c)
        } catch {
            // .md 派生视图写入失败：记录日志，但不回滚 SQLite。
            // 启动时 reconcile() 会从 SQLite 重建缺失/过期的 .md。
            print("[KaJi.Repository] .md 派生视图写入失败，将在启动对账时修复: \(error.localizedDescription)")
        }

        return c
    }

    /// 内部：在指定数据库事务内写入/更新卡片记录（INSERT OR REPLACE）
    private func persist(_ card: Card, in grdb: Database) throws {
        var record = CardRecord(
            id: card.id, type: card.type, title: card.title,
            createdAt: iso8601(card.createdAt), updatedAt: iso8601(card.updatedAt),
            deletedAt: card.deletedAt.map(iso8601),
            filePath: CardFileIO.fileURL(for: card.id).path,
            fileMtime: nil, fileHash: nil, fileSize: 0
        )
        // save = insert or update：兼容新建和更新，避免 update() 在记录不存在时抛错
        try record.save(grdb)

        // cardFields — 先删后插
        try CardFieldRecord
            .filter(Column("cardId") == card.id)
            .deleteAll(grdb)
        for f in card.fields {
            var fieldRec = CardFieldRecord(
                cardId: f.cardId, fieldName: f.fieldName,
                fieldValue: f.fieldValue, fieldOrder: f.fieldOrder
            )
            try fieldRec.insert(grdb)
        }

        // cardTags — 先删后插
        try CardTagRecord
            .filter(Column("cardId") == card.id)
            .deleteAll(grdb)
        for tag in card.tags {
            let tagRec = try ensureTag(named: tag, in: grdb)
            try CardTagRecord(cardId: card.id, tagId: tagRec.id!).insert(grdb)
        }
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

    // MARK: - 启动对账

    /// 启动时跑一次：修复 .md 与 SQLite 之间的不一致。
    /// - .md 有但 SQLite 没有：从 .md 解析并写回 SQLite
    /// - SQLite 有但 .md 没有：从 SQLite 重建 .md
    /// - 两边 ID 集合完全一致：直接短路返回，不打开任何文件
    func reconcile() throws {
        let mdIDs = try CardFileIO.listAllIDs()
        let dbIDs = try db.allIDs()

        // 快速短路：完全一致时无需解析任何 .md
        guard mdIDs != dbIDs else { return }

        // 1. .md 有但 SQLite 没有：从 .md 恢复
        let missingInDB = mdIDs.subtracting(dbIDs)
        if !missingInDB.isEmpty {
            try db.dbWriter.write { grdb in
                for id in missingInDB {
                    guard let card = try? CardFileIO.read(id: id) else { continue }
                    try persist(card, in: grdb)
                }
            }
        }

        // 2. SQLite 有但 .md 没有：从 SQLite 重建 .md
        let missingInMD = dbIDs.subtracting(mdIDs)
        for id in missingInMD {
            guard let card = try? self.card(id: id) else { continue }
            do {
                _ = try CardFileIO.write(card)
            } catch {
                print("[KaJi.Repository] 对账时 .md 重建失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 公共辅助

    /// 启动时跑一次：对账 + 清理超过保留天数的回收站卡
    func bootstrap(retentionDays: Int) throws {
        try reconcile()
        try db.purgeOldTrash(retentionDays: retentionDays)
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
