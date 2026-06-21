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
//  5. 搜索统一走内存缓存 filter（StatsState.cachedSummaries），不再维护 FTS5 索引
//  6. 回收站：del(card) 改 deletedAt，不删 .md；restore 改回 null；purge 真删
//  7. 启动对账（reconcile）：自动修复 .md 与 SQLite 之间的历史不一致
//

import Foundation
import os
@preconcurrency import GRDB

/// reconcileCritical 的返回值，让 UI 能看到失败
/// 用 String? 存储首个错误描述（Error 不满足 Sendable，无法从 @Sendable 数据库闭包返回）
struct ReconcileResult: Sendable {
    var restoredCount: Int = 0
    var failedCount: Int = 0
    var failedIDs: [String] = []
    var firstErrorDescription: String?
}

final class CardRepository: @unchecked Sendable {
    fileprivate let db: AppDatabase
    static let shared = CardRepository()

    private static let log = Logger(subsystem: "com.kaji.app", category: "repository")

    private init(db: AppDatabase = .shared) { self.db = db }

    /// 异步读单卡，避免主线程同步 I/O 阻塞
    func cardAsync(id: String) async throws -> Card? {
        let grdb = db.dbWriter
        return try await Task.detached(priority: .userInitiated) {
            try grdb.read { db in
                guard let rec = try CardRecord.fetchOne(db, key: id) else { return nil }
                return try self.hydrate(record: rec, in: db)
            }
        }.value
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
            return try hydrate(records: recs, in: grdb)
        }
    }

    // MARK: - 写入

    /// 保存/更新一张卡（SQLite 是强一致锚点，.md 是派生视图）
    /// - 先提交 SQLite 事务；事务成功后再写 .md
    /// - .md 写入失败不会破坏 SQLite 一致性，启动对账会修复
    /// - ContentLimit 截断由 caller 负责（保证 UI 同步），
    ///   传过来的卡应当已通过 ContentLimit.truncate
    /// - 每次保存 c.mdVersion += 1；.md 走 MarkdownWriteQueue 串行
    func save(card: Card) throws -> Card {
        var c = card
        c.updatedAt = Date()
        // 每次 SQLite 写 +1；reconcile 通过比对 .md frontmatter.mdVersion
        // 检测 .md 是否落后；落后则入队重写
        c.mdVersion += 1

        // 防御性兜底 — 拒绝保存已删除的卡片（deletedAt != nil）。
        // 即使 Service 层未及时 flush，任何延迟到达的 save 都不会复活已删除/回收中的卡。
        if c.deletedAt != nil {
            throw DatabaseError.deletedCardSaveAttempt(cardId: c.id)
        }

        // 1. SQLite 事务（ACID）：cards + cardFields + cardTags
        try db.dbWriter.write { grdb in
            try persist(c, in: grdb)
        }

        // 2. .md 走 MarkdownWriteQueue（actor 串行化）
        let cardCopy = c
        Task {
            await MarkdownWriteQueue.shared.enqueue(cardCopy)
        }

        return c
    }

    /// 在指定数据库事务内写入/更新卡片记录。
    /// - 已存在卡：先 UPDATE cards；子表（cardFields/cardTags）先删后插。
    /// - 新卡：UPDATE 影响 0 行，再 INSERT。
    /// - 多进程 race 仍由 CardService 捕获 SQLITE_CONSTRAINT 重试。
    private func persist(_ card: Card, in grdb: Database) throws {
        let filePath = try CardFileIO.fileURL(for: card.id).path
        var record = CardRecord(
            id: card.id, type: card.type, title: card.title,
            createdAt: iso8601(card.createdAt), updatedAt: iso8601(card.updatedAt),
            deletedAt: card.deletedAt.map(iso8601),
            filePath: filePath,
            fileMtime: nil, fileHash: nil, fileSize: 0,
            mdVersion: card.mdVersion
        )

        // 1. 主表：先 UPDATE，不存在再 INSERT。
        //    避免只用 INSERT 导致编辑已存在卡时主键冲突、被误判为新卡的问题。
        try grdb.execute(sql: """
            UPDATE cards SET
                type = ?,
                title = ?,
                createdAt = ?,
                updatedAt = ?,
                deletedAt = ?,
                filePath = ?,
                fileMtime = ?,
                fileHash = ?,
                fileSize = ?,
                mdVersion = ?
            WHERE id = ?
            """, arguments: [
                record.type, record.title, record.createdAt, record.updatedAt, record.deletedAt,
                record.filePath, record.fileMtime, record.fileHash, record.fileSize, record.mdVersion,
                record.id
            ])
        let updated = grdb.changesCount

        if updated == 0 {
            do {
                try record.insert(grdb)
            } catch let grdbError as GRDB.DatabaseError
                where grdbError.resultCode == .SQLITE_CONSTRAINT {
                // 多进程同时写同一 ID — 抛错由 Service 层重试
                throw DatabaseError.idConflict(cardId: card.id)
            }
        }

        // 2. cardFields — 先删后插
        try CardFieldRecord
            .filter(Column("cardId") == card.id)
            .deleteAll(grdb)
        let typeDef = CardTypeRegistry.shared.def(for: card.type)
        let orderedFieldNames = typeDef.allFields
        for f in card.fields {
            let fieldName = f.fieldOrder < orderedFieldNames.count ? orderedFieldNames[f.fieldOrder] : f.fieldName
            var fieldRec = CardFieldRecord(
                cardId: f.cardId, fieldName: fieldName,
                fieldValue: f.fieldValue, fieldOrder: f.fieldOrder
            )
            try fieldRec.insert(grdb)
        }

        // 3. cardTags — 先删后插
        try CardTagRecord
            .filter(Column("cardId") == card.id)
            .deleteAll(grdb)
        for tag in card.tags {
            let tagId = try ensureTag(named: tag, in: grdb)
            try CardTagRecord(cardId: card.id, tagId: tagId).insert(grdb)
        }

        // 4. cardsFts — 同步搜索索引
        try grdb.execute(sql: "DELETE FROM cardsFts WHERE id = ?", arguments: [card.id])
        let searchText = ([card.title] + card.tags + card.fields.map { $0.fieldValue }).joined(separator: " ")
        try grdb.execute(sql: "INSERT INTO cardsFts (id, searchText) VALUES (?, ?)", arguments: [card.id, searchText])
    }

    // MARK: - 删除 / 回收站

    /// 移到回收站（改 deletedAt；不删 .md）
    /// 不阻塞 softDelete 主流程（用户体验优先）；失败由 .md_failures 标记 + reconcile 重试。
    /// mdVersion += 1；.md 走 MarkdownWriteQueue 串行化
    func softDelete(id: String) throws {
        let now = iso8601(Date())
        try db.dbWriter.write { grdb in
            try grdb.execute(sql: """
                UPDATE cards SET deletedAt = ?, updatedAt = ?, mdVersion = mdVersion + 1 WHERE id = ?
                """, arguments: [now, now, id])
        }

        // .md 走队列（actor 串行处理 + 去重 + 失败解耦）
        let cardId = id
        Task {
            guard let card = try? CardRepository.shared.card(id: cardId) else { return }
            await MarkdownWriteQueue.shared.enqueue(card)
        }
    }

    /// 把完整内容回写 + 同时置 deletedAt（单事务原子）。
    /// 用于"卡片被逐步清空 → 回收站但保留清空前完整内容"场景。
    /// 与 save() 的区别：save() 防御性拒绝 deletedAt != nil 的卡；本方法专门写入
    /// 带 deletedAt 的完整内容（content + 软删除标记一次落库，不会出现中间残缺态）。
    func softDeletePreservingContent(_ card: Card) throws {
        var c = card
        c.updatedAt = Date()
        c.mdVersion += 1
        c.deletedAt = Date()

        try db.dbWriter.write { grdb in
            try persist(c, in: grdb)
        }

        let cardCopy = c
        Task {
            await MarkdownWriteQueue.shared.enqueue(cardCopy)
        }
    }

    /// 从回收站恢复（deletedAt = NULL）
    /// 同 softDelete，SQLite 成功后异步重写 .md 反映 deletedAt=nil。
    /// mdVersion += 1；.md 走 MarkdownWriteQueue 串行化
    func restore(id: String) throws {
        let now = iso8601(Date())
        try db.dbWriter.write { grdb in
            try grdb.execute(sql: """
                UPDATE cards SET deletedAt = NULL, updatedAt = ?, mdVersion = mdVersion + 1 WHERE id = ?
                """, arguments: [now, id])
        }

        let cardId = id
        Task {
            guard let card = try? CardRepository.shared.card(id: cardId) else { return }
            await MarkdownWriteQueue.shared.enqueue(card)
        }
    }

    // MARK: - 实时查询 (配合 ValueObservation)

    func fetchTypeCounts(db: Database) throws -> [String: Int] {
        let typeRows = try Row.fetchAll(db, sql: """
            SELECT type, COUNT(*) AS cnt FROM cards
            WHERE deletedAt IS NULL
            GROUP BY type
            """)
        let registry = CardTypeRegistry.shared
        var typeDict: [String: Int] = Dictionary(
            uniqueKeysWithValues: registry.ordered.map { ($0.id, 0) }
        )
        for row in typeRows {
            let type: String = row["type"] ?? "自由卡"
            let cnt: Int = row["cnt"] ?? 0
            let typeId = registry.def(for: type).id
            typeDict[typeId, default: 0] += cnt
        }
        return typeDict
    }

    func fetchTagCounts(db: Database) throws -> [(String, Int)] {
        let tagRows = try Row.fetchAll(db, sql: """
            SELECT t.name, COUNT(*) AS cnt FROM tags t
            JOIN cardTags ct ON ct.tagId = t.id
            JOIN cards c ON c.id = ct.cardId
            WHERE c.deletedAt IS NULL
            GROUP BY t.name
            ORDER BY cnt DESC
            """)
        return tagRows.map { row in
            (row["name"] ?? "", row["cnt"] ?? 0)
        }
    }

    func fetchTrashCount(db: Database) throws -> Int {
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards WHERE deletedAt IS NOT NULL") ?? 0
    }

    func fetchFilteredCards(db: Database, filter: ListFilter?) throws -> [CardSummary] {
        let sql: String
        let arguments: StatementArguments

        switch filter {
        case .all, .none:
            sql = "SELECT id, type, title, updatedAt, deletedAt FROM cards WHERE deletedAt IS NULL ORDER BY updatedAt DESC, id ASC"
            arguments = []
        case .trash:
            sql = "SELECT id, type, title, updatedAt, deletedAt FROM cards WHERE deletedAt IS NOT NULL ORDER BY updatedAt DESC, id ASC"
            arguments = []
        case .type(let typeId):
            sql = "SELECT id, type, title, updatedAt, deletedAt FROM cards WHERE type = ? AND deletedAt IS NULL ORDER BY updatedAt DESC, id ASC"
            arguments = [typeId]
        case .tag(let tag):
            sql = """
                SELECT c.id, c.type, c.title, c.updatedAt, c.deletedAt 
                FROM cards c
                JOIN cardTags ct ON c.id = ct.cardId
                JOIN tags t ON ct.tagId = t.id
                WHERE t.name = ? AND c.deletedAt IS NULL
                ORDER BY c.updatedAt DESC, c.id ASC
                """
            arguments = [tag]
        case .search(let keyword):
            let terms = keyword.split(whereSeparator: { $0.isWhitespace })
                .map { "\"\($0)\"" }
                .joined(separator: " AND ")
            
            if terms.isEmpty {
                sql = "SELECT id, type, title, updatedAt, deletedAt FROM cards WHERE deletedAt IS NULL ORDER BY updatedAt DESC, id ASC"
                arguments = []
            } else {
                sql = """
                    SELECT c.id, c.type, c.title, c.updatedAt, c.deletedAt
                    FROM cards c
                    JOIN cardsFts fts ON c.id = fts.id
                    WHERE cardsFts MATCH ? AND c.deletedAt IS NULL
                    ORDER BY c.updatedAt DESC, c.id ASC
                    """
                arguments = [terms]
            }
        }

        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        guard !rows.isEmpty else { return [] }

        // Fetch tags efficiently
        let tagRows = try Row.fetchAll(db, sql: """
            SELECT ct.cardId, t.name 
            FROM tags t
            JOIN cardTags ct ON ct.tagId = t.id
            """)
        var tagsByCard: [String: [String]] = [:]
        for row in tagRows {
            guard let cardId: String = row["cardId"], let name: String = row["name"] else { continue }
            tagsByCard[cardId, default: []].append(name)
        }

        return rows.map { row in
            let id: String = row["id"] ?? ""
            let type: String = row["type"] ?? "自由卡"
            let title: String = row["title"] ?? ""
            let updatedAt = parseISO(row["updatedAt"] as? String ?? "") ?? Date()
            let deletedAt = (row["deletedAt"] as? String).flatMap(parseISO)
            
            return CardSummary(
                id: id,
                type: type,
                title: title,
                tags: tagsByCard[id]?.sorted() ?? [],
                searchText: "",
                updatedAt: updatedAt,
                deletedAt: deletedAt
            )
        }
    }

    // MARK: - 内部辅助

    /// 内部：把单条 record → Card
    private func hydrate(record rec: CardRecord, in grdb: Database) throws -> Card {
        return try hydrate(records: [rec], in: grdb)[0]
    }

    /// 批量把 records → Cards（一次性 JOIN 拉取 fields/tags，避免 N+1）
    /// 按 cardId 顺序预填充空数组，避免 Dictionary 默认值的 CoW 复制
    private func hydrate(records: [CardRecord], in grdb: Database) throws -> [Card] {
        guard !records.isEmpty else { return [] }

        let ids = records.map { $0.id }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(ids)

        // 1. 批量查 fields（按 cardId 排序以利分组）
        let fieldsSQL = """
            SELECT cardId, fieldName, fieldValue, fieldOrder
            FROM cardFields
            WHERE cardId IN (\(placeholders))
            ORDER BY cardId, fieldOrder
            """
        let fieldRecords = try CardFieldRecord.fetchAll(grdb, sql: fieldsSQL, arguments: args)
        var fieldsByCard: [String: [CardField]] = [:]
        var lastFieldCardId: String? = nil
        for rec in fieldRecords {
            if rec.cardId != lastFieldCardId {
                fieldsByCard[rec.cardId] = []   // 一次性建空数组，无 CoW
                lastFieldCardId = rec.cardId
            }
            fieldsByCard[rec.cardId]!.append(
                CardField(cardId: rec.cardId, fieldName: rec.fieldName ?? "", fieldValue: rec.fieldValue, fieldOrder: rec.fieldOrder)
            )
        }

        // 2. 批量查 tags（同 CoW 修复模式）
        let tagsSQL = """
            SELECT ct.cardId, t.name
            FROM tags t
            JOIN cardTags ct ON ct.tagId = t.id
            WHERE ct.cardId IN (\(placeholders))
            ORDER BY ct.cardId, t.name ASC
            """
        let tagRows = try Row.fetchAll(grdb, sql: tagsSQL, arguments: args)
        var tagsByCard: [String: [String]] = [:]
        var lastTagCardId: String? = nil
        for row in tagRows {
            guard let cardId: String = row["cardId"], let name: String = row["name"] else {
                throw DatabaseError.tagJoinParseFailed
            }
            if cardId != lastTagCardId {
                tagsByCard[cardId] = []
                lastTagCardId = cardId
            }
            tagsByCard[cardId]!.append(name)
        }

        // 3. 组装
        return records.map { rec in
            let typeId = rec.type.isEmpty ? "自由卡" : rec.type
            let typeDef = CardTypeRegistry.shared.def(for: typeId)
            let rawFields = fieldsByCard[rec.id] ?? []
            let alignedFields = Self.alignFields(rawFields, with: typeDef, cardId: rec.id)
            return Card(
                id: rec.id, type: rec.type, title: rec.title,
                tags: tagsByCard[rec.id] ?? [],
                fields: alignedFields,
                createdAt: parseISO(rec.createdAt) ?? Date(),
                updatedAt: parseISO(rec.updatedAt) ?? Date(),
                deletedAt: rec.deletedAt.flatMap(parseISO),
                mdVersion: rec.mdVersion
            )
        }
    }

    /// 按当前类型定义对齐字段名（方案甲：字段名跟定义走）
    private static func alignFields(_ rawFields: [CardField], with typeDef: CardTypeDef, cardId: String) -> [CardField] {
        let orderedFieldNames = typeDef.allFields
        return rawFields.sorted { $0.fieldOrder < $1.fieldOrder }.enumerated().compactMap { index, field in
            guard index < orderedFieldNames.count else { return nil }
            return CardField(
                cardId: cardId,
                fieldName: orderedFieldNames[index],
                fieldValue: field.fieldValue,
                fieldOrder: index
            )
        }
    }

    // MARK: - SQL 聚合统计

    /// 内部：建/取标签，返回标签 id（不存在则插入）
    private func ensureTag(named name: String, in grdb: Database) throws -> Int64 {
        if let existing = try TagRecord.filter(Column("name") == name).fetchOne(grdb) {
            guard let id = existing.id else {
                throw DatabaseError.tagRecordMissingId
            }
            return id
        }
        var rec = TagRecord(id: nil, name: name)
        try rec.insert(grdb)
        guard let id = rec.id else {
            throw DatabaseError.tagInsertMissingId
        }
        return id
    }

    // MARK: - 启动对账

    /// 启动时跑一次：修复 .md 与 SQLite 之间的不一致。
    /// - .md 有但 SQLite 没有：从 .md 解析并写回 SQLite
    /// - SQLite 有但 .md 没有：从 SQLite 重建 .md
    /// - 两边 ID 集合完全一致：仍要校验 mdVersion
    /// - mdVersion 落后：从 SQLite 重建对应 .md
    ///
    /// 关键对账（影响首屏 DB 数据完整性，必须在首屏渲染前同步完成）：
    /// 仅处理「.md 有但 SQLite 没有」—— 把 .md 恢复进 DB，否则首屏会漏卡。
    /// 通常 missingInDB 为空集，开销极小（listAllIDs + allIDs 各一次）。
    /// - Returns: ReconcileResult 包含恢复成功数、失败数、失败 ID 列表及首个错误描述
    func reconcileCritical() async throws -> ReconcileResult {
        let mdIDs = try CardFileIO.listAllIDs()
        let dbIDs = try db.allIDs()

        // .md 有但 SQLite 没有：从 .md 恢复（影响首屏数据完整性）
        let missingInDB = mdIDs.subtracting(dbIDs)
        guard !missingInDB.isEmpty else { return ReconcileResult() }

        // 在 @Sendable 数据库写闭包内构造局部结果，避免并发修改外部 var
        let result = try await db.dbWriter.write { grdb -> ReconcileResult in
            var partial = ReconcileResult()
            for id in missingInDB {
                do {
                    guard let card = try CardFileIO.read(id: id) else {
                        Self.log.notice("对账时未找到 .md: \(id, privacy: .public)")
                        continue
                    }
                    try persist(card, in: grdb)
                    partial.restoredCount += 1
                } catch {
                    partial.failedCount += 1
                    partial.failedIDs.append(id)
                    if partial.firstErrorDescription == nil {
                        partial.firstErrorDescription = error.localizedDescription
                    }
                    Self.log.error("对账时恢复 .md 到 SQLite 失败 (\(id, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
            }
            return partial
        }
        return result
    }

    /// 延迟对账（纯 .md 派生视图修复，不影响首屏 DB 数据，可在首屏后后台低优先级跑）：
    /// - SQLite 有但 .md 没有：补写 .md
    /// - mdVersion 校验：逐 .md 读首行比对（10万卡时的 P0 瓶颈，移出关键路径）
    /// - retryFailures：重试之前写入失败的 .md
    func reconcileDeferred() async throws {
        let mdIDs = try CardFileIO.listAllIDs()
        let dbIDs = try db.allIDs()

        // SQLite 有但 .md 没有：从 SQLite 重建 .md（只补 .md，不影响 DB）
        let missingInMD = dbIDs.subtracting(mdIDs)
        if !missingInMD.isEmpty {
            let placeholders = missingInMD.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(missingInMD)
            do {
                let cards = try await db.dbWriter.read { grdb in
                    let recs = try CardRecord.fetchAll(grdb, sql: """
                        SELECT * FROM cards WHERE id IN (\(placeholders))
                        """, arguments: args)
                    return try self.hydrate(records: recs, in: grdb)
                }
                for card in cards {
                    await MarkdownWriteQueue.shared.enqueue(card)
                }
            } catch {
                Self.log.error("对账时 IN 查询失败: \(error.localizedDescription, privacy: .public)")
            }
        }

        // mdVersion 校验（终极一致性保障；P0 瓶颈，已移出首屏关键路径）
        try checkMarkdownVersionConsistency()

        // 扫 .md_failures 目录，重试之前写入失败的 .md
        await MarkdownWriteQueue.shared.retryFailures()
    }

    func updateFileMtime(id: String, mtime: Double) async throws {
        try await db.dbWriter.write { grdb in
            try grdb.execute(sql: "UPDATE cards SET fileMtime = ? WHERE id = ?", arguments: [mtime, id])
        }
    }

    /// 扫描所有 .md frontmatter 第一行的 mdVersion，与 SQLite 对比；
    /// 落后 / 缺失 mdVersion 字段的 .md 一律入队重写
    private func checkMarkdownVersionConsistency() throws {
        // 1. 一次性把 SQLite 中所有 (id → (mdVersion, fileMtime)) 拉出来
        let byID: [String: (version: Int64, mtime: Double?)]
        do {
            byID = try db.dbWriter.read { grdb -> [String: (Int64, Double?)] in
                let rows = try Row.fetchAll(grdb, sql: """
                    SELECT id, mdVersion, fileMtime FROM cards
                    """)
                var dict: [String: (Int64, Double?)] = [:]
                for row in rows {
                    if let id: String = row["id"], let v: Int64 = row["mdVersion"] {
                        let mtime: Double? = row["fileMtime"]
                        dict[id] = (v, mtime)
                    }
                }
                return dict
            }
        } catch {
            Self.log.error("checkMarkdownVersionConsistency 拉取 SQLite 失败: \(error.localizedDescription, privacy: .public)")
            return
        }

        // 2. 遍历 cards/ 目录所有 .md；读 mtime 并比对
        let mdDir: URL
        do {
            mdDir = try CardFileIO.cardsDir()
        } catch {
            Self.log.error("checkMarkdownVersionConsistency 取 cardsDir 失败: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: mdDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        var mtimeUpdates: [(String, Double)] = []
        
        for case let mdURL as URL in enumerator where mdURL.pathExtension == "md" {
            let id = mdURL.deletingPathExtension().lastPathComponent
            guard let dbRec = byID[id] else { continue }   // .md 在 SQLite 找不到（罕见 race）跳过
            
            let resourceValues = try? mdURL.resourceValues(forKeys: [.contentModificationDateKey])
            let fileMtime = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
            
            // 如果 fileMtime 与 DB 记录的完全一致（误差<1秒），跳过文件读取（避免 10 万次 FileHandle 开启）
            if let dbMtime = dbRec.mtime, abs(fileMtime - dbMtime) < 1.0 {
                continue
            }

            // 只读 .md 第一行
            guard let handle = try? FileHandle(forReadingFrom: mdURL) else {
                // .md 不可读，入队重写
                awaitEnqueueFallback(id: id)
                continue
            }
            let firstLineData = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            guard let firstLineText = String(data: firstLineData, encoding: .utf8) else {
                awaitEnqueueFallback(id: id)
                continue
            }
            // frontmatter 第一行形式：`mdVersion: <int>`
            let firstLine = firstLineText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if firstLine.hasPrefix("mdVersion:"),
               let mdVersion = Int64(firstLine.dropFirst("mdVersion:".count).trimmingCharacters(in: .whitespaces)) {
                if mdVersion < dbRec.version {
                    // .md 落后于 SQLite
                    awaitEnqueueFallback(id: id)
                } else {
                    // .md 版本一致或更新，更新 SQLite 的 fileMtime
                    mtimeUpdates.append((id, fileMtime))
                }
            } else if !firstLine.hasPrefix("mdVersion:") {
                // 老格式 .md（无 mdVersion 字段）— 入队重写
                awaitEnqueueFallback(id: id)
            }
        }
        
        // 3. 批量更新 mtime
        if !mtimeUpdates.isEmpty {
            do {
                try db.dbWriter.write { grdb in
                    for (id, mtime) in mtimeUpdates {
                        try grdb.execute(sql: "UPDATE cards SET fileMtime = ? WHERE id = ?", arguments: [mtime, id])
                    }
                }
            } catch {
                Self.log.error("批量更新 fileMtime 失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 异步入队重写单卡 .md（id 已知；具体 card 从 SQLite 读）
    private func awaitEnqueueFallback(id: String) {
        Task { [id] in
            guard let card = try? CardRepository.shared.card(id: id) else { return }
            await MarkdownWriteQueue.shared.enqueue(card)
        }
    }

    // MARK: - 公共辅助

    /// 供 CardService.bootstrapDeferred 调用的 purge 转发（内部用 withTaskGroup 限流）
    func purgeOldTrashPublic(retentionDays: Int) async throws {
        try await db.purgeOldTrash(retentionDays: retentionDays)
    }

    /// DB 是否处于 in-memory 模式（fallback）— UI 层可以展示警告
    var isInMemory: Bool { db.isInMemory }

    private func iso8601(_ d: Date) -> String {
        DateFormatting.string(d)
    }
    private func parseISO(_ s: String) -> Date? {
        DateFormatting.parse(s)
    }
}
