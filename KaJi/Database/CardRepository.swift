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
        for f in card.fields {
            var fieldRec = CardFieldRecord(
                cardId: f.cardId, fieldName: f.fieldName,
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
                CardField(cardId: rec.cardId, fieldName: rec.fieldName, fieldValue: rec.fieldValue, fieldOrder: rec.fieldOrder)
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
            Card(
                id: rec.id, type: rec.type, title: rec.title,
                tags: tagsByCard[rec.id] ?? [],
                fields: fieldsByCard[rec.id] ?? [],
                createdAt: parseISO(rec.createdAt) ?? Date(),
                updatedAt: parseISO(rec.updatedAt) ?? Date(),
                deletedAt: rec.deletedAt.flatMap(parseISO),
                mdVersion: rec.mdVersion
            )
        }
    }

    // MARK: - SQL 聚合统计

    /// 3 路 SQL 聚合刷新侧栏统计 — 不 hydrate 完整 Card
    /// 1. typeCounts：GROUP BY type 聚合
    /// 2. tagCounts：JOIN cardTags + tags GROUP BY name
    /// 3. summaries：轻量字段（id/type/title/updatedAt/deletedAt）+ tags 批量查
    ///   性能：10k 卡全库 ~10ms（vs 修复前 hydrate 全库 ~100ms）
    /// 三查询合并为单事务，消除事务间数据不一致窗口
    func refreshStatsSQL() throws -> (
        summaries: [CardSummary],
        typeCounts: [CardType: Int],
        tagCounts: [(String, Int)]
    ) {
        try db.dbWriter.read { grdb -> (
            summaries: [CardSummary],
            typeCounts: [CardType: Int],
            tagCounts: [(String, Int)]
        ) in
            // 1. typeCounts
            let typeRows = try Row.fetchAll(grdb, sql: """
                SELECT type, COUNT(*) AS cnt FROM cards
                WHERE deletedAt IS NULL
                GROUP BY type
                """)
            var typeDict: [CardType: Int] = Dictionary(
                uniqueKeysWithValues: CardType.allCases.map { ($0, 0) }
            )
            for row in typeRows {
                let type: String = row["type"] ?? "free"
                let cnt: Int = row["cnt"] ?? 0
                typeDict[CardType(rawValue: type) ?? .free, default: 0] += cnt
            }

            // 2. tagCounts（JOIN cardTags + tags）
            let tagRows = try Row.fetchAll(grdb, sql: """
                SELECT t.name, COUNT(*) AS cnt FROM tags t
                JOIN cardTags ct ON ct.tagId = t.id
                JOIN cards c ON c.id = ct.cardId
                WHERE c.deletedAt IS NULL
                GROUP BY t.name
                ORDER BY cnt DESC
                """)

            // 3. summaries：仅查轻量字段，tags + fields 单独批量查
            //    summaries 必须包含 deleted 卡，否则回收站永远为空。
            //    主列表/搜索在 ListState.filteredCards 中按 deletedAt 过滤。
            let recs = try Row.fetchAll(grdb, sql: """
                SELECT id, type, title, updatedAt, deletedAt FROM cards
                ORDER BY updatedAt DESC
                """)

            var summaries: [CardSummary] = []
            if !recs.isEmpty {
                let ids = recs.map { $0["id"] as? String ?? "" }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(ids)

                // 批量查 tags（按 cardId 排序以利 CoW 修复模式）
                let tagSQL = """
                    SELECT ct.cardId, t.name FROM tags t
                    JOIN cardTags ct ON ct.tagId = t.id
                    WHERE ct.cardId IN (\(placeholders))
                    ORDER BY ct.cardId, t.name ASC
                    """
                let cardTagRows = try Row.fetchAll(grdb, sql: tagSQL, arguments: args)
                var tagsByCard: [String: [String]] = [:]
                var lastTagCardId: String? = nil
                for row in cardTagRows {
                    guard let cardId: String = row["cardId"], let name: String = row["name"] else { continue }
                    if cardId != lastTagCardId {
                        tagsByCard[cardId] = []
                        lastTagCardId = cardId
                    }
                    tagsByCard[cardId]!.append(name)
                }

                // 批量查 fields（仅 value，不查 name/order）用于拼 searchText
                let fieldSQL = """
                    SELECT cardId, fieldValue FROM cardFields
                    WHERE cardId IN (\(placeholders))
                    ORDER BY cardId, fieldOrder
                    """
                let fieldRows = try Row.fetchAll(grdb, sql: fieldSQL, arguments: args)
                var fieldValuesByCard: [String: [String]] = [:]
                var lastFieldCardId: String? = nil
                for row in fieldRows {
                    guard let cardId: String = row["cardId"], let value: String = row["fieldValue"] else { continue }
                    if cardId != lastFieldCardId {
                        fieldValuesByCard[cardId] = []
                        lastFieldCardId = cardId
                    }
                    fieldValuesByCard[cardId]!.append(value)
                }

                summaries = recs.map { row in
                    let id: String = row["id"] ?? ""
                    let type: String = row["type"] ?? "free"
                    let title: String = row["title"] ?? ""
                    let tags = tagsByCard[id] ?? []
                    let fieldValues = fieldValuesByCard[id] ?? []
                    let updatedAt = parseISO(row["updatedAt"] as? String ?? "") ?? Date()
                    let deletedAt = (row["deletedAt"] as? String).flatMap(parseISO)
                    // title + tags + 字段值预拼接，tokenize 一次覆盖全部
                    let searchText = ([title] + tags + fieldValues).joined(separator: " ")
                    return CardSummary(
                        id: id, type: type, title: title,
                        tags: tags,
                        searchText: searchText,
                        updatedAt: updatedAt,
                        deletedAt: deletedAt
                    )
                }
            }

            let tagCounts: [(String, Int)] = tagRows.map { row in
                (row["name"] ?? "", row["cnt"] ?? 0)
            }
            return (summaries: summaries, typeCounts: typeDict, tagCounts: tagCounts)
        }
    }

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

    /// 扫描所有 .md frontmatter 第一行的 mdVersion，与 SQLite 对比；
    /// 落后 / 缺失 mdVersion 字段的 .md 一律入队重写
    private func checkMarkdownVersionConsistency() throws {
        // 1. 一次性把 SQLite 中所有 (id → mdVersion) 拉出来（不 hydrate 全字段）
        let byID: [String: Int64]
        do {
            byID = try db.dbWriter.read { grdb -> [String: Int64] in
                let rows = try Row.fetchAll(grdb, sql: """
                    SELECT id, mdVersion FROM cards
                    """)
                var dict: [String: Int64] = [:]
                for row in rows {
                    if let id: String = row["id"], let v: Int64 = row["mdVersion"] {
                        dict[id] = v
                    }
                }
                return dict
            }
        } catch {
            Self.log.error("checkMarkdownVersionConsistency 拉取 SQLite 失败: \(error.localizedDescription, privacy: .public)")
            return
        }

        // 2. 遍历 cards/ 目录所有 .md；读 frontmatter 第一行的 mdVersion
        let mdDir: URL
        do {
            mdDir = try CardFileIO.cardsDir()
        } catch {
            Self.log.error("checkMarkdownVersionConsistency 取 cardsDir 失败: \(error.localizedDescription, privacy: .public)")
            return
        }
        let mdURLs = (try? FileManager.default.contentsOfDirectory(at: mdDir, includingPropertiesForKeys: nil)) ?? []
        for mdURL in mdURLs where mdURL.pathExtension == "md" {
            let id = mdURL.deletingPathExtension().lastPathComponent
            guard let dbVersion = byID[id] else { continue }   // .md 在 SQLite 找不到（罕见 race）跳过

            // 只读 .md 第一行（避免解析整个 body，10k 卡库时 O(N) 文本解析会很慢）
            guard let handle = try? FileHandle(forReadingFrom: mdURL) else {
                // .md 不可读，入队重写
                awaitEnqueueFallback(id: id)
                continue
            }
            defer { try? handle.close() }
            let firstLineData = (try? handle.read(upToCount: 4096)) ?? Data()
            guard let firstLineText = String(data: firstLineData, encoding: .utf8) else {
                awaitEnqueueFallback(id: id)
                continue
            }
            // frontmatter 第一行形式：`mdVersion: <int>`（在 `id:` 之后）
            let firstLine = firstLineText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if firstLine.hasPrefix("mdVersion:"),
               let mdVersion = Int64(firstLine.dropFirst("mdVersion:".count).trimmingCharacters(in: .whitespaces)),
               mdVersion < dbVersion {
                // .md 落后于 SQLite
                awaitEnqueueFallback(id: id)
            } else if !firstLine.hasPrefix("mdVersion:") {
                // 老格式 .md（无 mdVersion 字段）— 入队重写
                awaitEnqueueFallback(id: id)
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
