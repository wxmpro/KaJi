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
import os
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
            return try hydrate(records: recs, in: grdb)
        }
    }

    // MARK: - 写入

    /// 保存/更新一张卡（SQLite 是强一致锚点，.md 是派生视图）
    /// - 先提交 SQLite 事务；事务成功后再写 .md
    /// - .md 写入失败不会破坏 SQLite 一致性，启动对账会修复
    /// 保存/更新一张卡（SQLite 是强一致锚点，.md 是派生视图）
    /// - 先提交 SQLite 事务；事务成功后再写 .md
    /// - .md 写入失败不会破坏 SQLite 一致性，启动对账会修复
    /// - **v1.3.0 P0-4 修复**：本方法不再做 ContentLimit 截断，统一由 caller
    ///   负责（EditorState.persistCurrentCard 已在主线程截断，以保证 UI 同步）。
    ///   旧实现主线程 + 后台双重 O(N) 字符统计浪费，且容易出现"caller 截断
    ///   逻辑"和"Repository 截断逻辑"分歧。caller 传过来的卡应当已通过
    ///   ContentLimit.truncate；如果 caller 不截断，那是 caller 的 bug。
    func save(card: Card) throws -> Card {
        var c = card
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
            let tagId = try ensureTag(named: tag, in: grdb)
            try CardTagRecord(cardId: card.id, tagId: tagId).insert(grdb)
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

    /// 内部：把单条 record → Card
    private func hydrate(record rec: CardRecord, in grdb: Database) throws -> Card {
        return try hydrate(records: [rec], in: grdb)[0]
    }

    /// 批量把 records → Cards（一次性 JOIN 拉取 fields/tags，避免 N+1）
    private func hydrate(records: [CardRecord], in grdb: Database) throws -> [Card] {
        guard !records.isEmpty else { return [] }

        let ids = records.map { $0.id }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(ids)

        // 1. 批量查 fields
        let fieldsSQL = """
            SELECT cardId, fieldName, fieldValue, fieldOrder
            FROM cardFields
            WHERE cardId IN (\(placeholders))
            ORDER BY fieldOrder
            """
        let fieldRecords = try CardFieldRecord.fetchAll(grdb, sql: fieldsSQL, arguments: args)
        var fieldsByCard: [String: [CardField]] = [:]
        for rec in fieldRecords {
            fieldsByCard[rec.cardId, default: []].append(
                CardField(cardId: rec.cardId, fieldName: rec.fieldName, fieldValue: rec.fieldValue, fieldOrder: rec.fieldOrder)
            )
        }

        // 2. 批量查 tags
        let tagsSQL = """
            SELECT ct.cardId, t.name
            FROM tags t
            JOIN cardTags ct ON ct.tagId = t.id
            WHERE ct.cardId IN (\(placeholders))
            ORDER BY t.name ASC
            """
        let tagRows = try Row.fetchAll(grdb, sql: tagsSQL, arguments: args)
        var tagsByCard: [String: [String]] = [:]
        for row in tagRows {
            guard let cardId: String = row["cardId"], let name: String = row["name"] else {
                throw NSError(domain: "CardRepository", code: 3, userInfo: [NSLocalizedDescriptionKey: "标签关联解析失败"])
            }
            tagsByCard[cardId, default: []].append(name)
        }

        // 3. 组装
        return records.map { rec in
            Card(
                id: rec.id, type: rec.type, title: rec.title,
                tags: tagsByCard[rec.id] ?? [],
                fields: fieldsByCard[rec.id] ?? [],
                createdAt: parseISO(rec.createdAt) ?? Date(),
                updatedAt: parseISO(rec.updatedAt) ?? Date(),
                deletedAt: rec.deletedAt.flatMap(parseISO)
            )
        }
    }

    /// 内部：建/取标签，返回标签 id（不存在则插入）
    private func ensureTag(named name: String, in grdb: Database) throws -> Int64 {
        if let existing = try TagRecord.filter(Column("name") == name).fetchOne(grdb) {
            guard let id = existing.id else {
                throw NSError(domain: "CardRepository", code: 2, userInfo: [NSLocalizedDescriptionKey: "标签记录缺少 id"])
            }
            return id
        }
        var rec = TagRecord(id: nil, name: name)
        try rec.insert(grdb)
        guard let id = rec.id else {
            throw NSError(domain: "CardRepository", code: 2, userInfo: [NSLocalizedDescriptionKey: "插入标签后未能获取 id"])
        }
        return id
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
                    do {
                        guard let card = try CardFileIO.read(id: id) else {
                            print("[KaJi.Repository] 对账时未找到 .md: \(id)")
                            continue
                        }
                        try persist(card, in: grdb)
                    } catch {
                        print("[KaJi.Repository] 对账时恢复 .md 到 SQLite 失败 (\(id)): \(error.localizedDescription)")
                    }
                }
            }
        }

        // 2. SQLite 有但 .md 没有：从 SQLite 重建 .md
        // v1.3.0 P0-3 修复：原实现对每个 missingInMD id 调一次 self.card(id:)，
        // 每次都是独立 dbWriter.read + hydrate（虽然 hydrate 内部已是 batch IN，
        // 但 N 次 dbWriter.read 仍是 N 次锁等待 + 串行执行）。改为一次 self.allCards
        // 批量拉全量 + dictionary 查，N=missingInMD.size 通常 < 10，但
        // 数据库 IO 从 O(N) 次降到 O(1) 次。
        let missingInMD = dbIDs.subtracting(mdIDs)
        if !missingInMD.isEmpty {
            do {
                let cards = try self.allCards(includeDeleted: true)
                let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
                for id in missingInMD {
                    guard let card = byID[id] else {
                        print("[KaJi.Repository] 对账时未找到 SQLite 记录: \(id)")
                        continue
                    }
                    _ = try CardFileIO.write(card)
                }
            } catch {
                print("[KaJi.Repository] 对账时批量拉全量失败，跳过 .md 重建: \(error.localizedDescription)")
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

    // ISO8601 helpers — formatter 用 nonisolated(unsafe) 声明，实际访问由 OSAllocatedUnfairLock 保护。
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterLock = OSAllocatedUnfairLock<Void>()

    private func iso8601(_ d: Date) -> String {
        Self.isoFormatterLock.withLock { Self.isoFormatter.string(from: d) }
    }
    private func parseISO(_ s: String) -> Date? {
        Self.isoFormatterLock.withLock {
            if let d = Self.isoFormatter.date(from: s) { return d }
            let simple = ISO8601DateFormatter()
            simple.formatOptions = [.withInternetDateTime]
            return simple.date(from: s)
        }
    }
}
