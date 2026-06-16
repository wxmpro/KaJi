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
    /// - **v1.3.0 P0-4 修复**：本方法不再做 ContentLimit 截断，统一由 caller
    ///   负责（EditorState.persistCurrentCard 已在主线程截断，以保证 UI 同步）。
    ///   旧实现主线程 + 后台双重 O(N) 字符统计浪费，且容易出现"caller 截断
    ///   逻辑"和"Repository 截断逻辑"分歧。caller 传过来的卡应当已通过
    ///   ContentLimit.truncate；如果 caller 不截断，那是 caller 的 bug。
    /// - **v1.3.0**：每次保存 c.mdVersion += 1；.md 走 MarkdownWriteQueue 串行
    func save(card: Card) throws -> Card {
        var c = card
        c.updatedAt = Date()
        // v1.3.0：每次 SQLite 写 +1；reconcile 通过比对 .md frontmatter.mdVersion
        // 检测 .md 是否落后；落后则入队重写
        c.mdVersion += 1

        // T1 P0 修复（v1.2.9）：防御性兜底 — 拒绝保存已删除的卡片（deletedAt != nil）。
        // 即使 Service 层未及时 flush，任何延迟到达的 save 都不会复活已删除/回收中的卡。
        // v1.3.0：改为结构化 DatabaseError
        if c.deletedAt != nil {
            throw DatabaseError.deletedCardSaveAttempt(cardId: c.id)
        }

        // 1. SQLite 事务（ACID）：cards + cardFields + cardTags
        try db.dbWriter.write { grdb in
            try persist(c, in: grdb)
        }

        // 2. v1.3.0：.md 走 MarkdownWriteQueue（actor 串行化），
        //    取代 v1.2.9 T4 的 fire-and-forget Task.detached 模板代码。
        let cardCopy = c
        Task {
            await MarkdownWriteQueue.shared.enqueue(cardCopy)
        }

        return c
    }

    /// 内部：在指定数据库事务内写入/更新卡片记录（INSERT OR REPLACE）
    private func persist(_ card: Card, in grdb: Database) throws {
        // v1.2.9 S1 修复：fileURL 改 throws
        let filePath = try CardFileIO.fileURL(for: card.id).path
        var record = CardRecord(
            id: card.id, type: card.type, title: card.title,
            createdAt: iso8601(card.createdAt), updatedAt: iso8601(card.updatedAt),
            deletedAt: card.deletedAt.map(iso8601),
            filePath: filePath,
            fileMtime: nil, fileHash: nil, fileSize: 0,
            mdVersion: card.mdVersion  // v1.3.0：写入当前 mdVersion
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
    /// v1.2.9 T4：SQLite 成功后异步重写 .md，反映 deletedAt。
    /// 不阻塞 softDelete 主流程（用户体验优先）；失败由 .md_failures 标记 + reconcile 重试。
    /// v1.3.0：mdVersion += 1；.md 走 MarkdownWriteQueue 串行化
    func softDelete(id: String) throws {
        let now = iso8601(Date())
        try db.dbWriter.write { grdb in
            try grdb.execute(sql: """
                UPDATE cards SET deletedAt = ?, updatedAt = ?, mdVersion = mdVersion + 1 WHERE id = ?
                """, arguments: [now, now, id])
        }

        // v1.3.0：.md 走队列（actor 串行处理 + 去重 + 失败解耦）
        let cardId = id
        Task {
            guard let card = try? CardRepository.shared.card(id: cardId) else { return }
            await MarkdownWriteQueue.shared.enqueue(card)
        }
    }

    /// 从回收站恢复（deletedAt = NULL）
    /// v1.2.9 T4：同 softDelete，SQLite 成功后异步重写 .md 反映 deletedAt=nil。
    /// v1.3.0：mdVersion += 1；.md 走 MarkdownWriteQueue 串行化
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
    /// v1.2.9 T5 CoW 修复：原 `fieldsByCard[id, default: []].append(...)` 每次
    /// append 都触发值类型数组复制（Dictionary 默认值是空数组，每次访问
    /// default 都触发 CoW）。改为按 cardId 顺序预填充空数组，避免复制。
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
                mdVersion: rec.mdVersion  // v1.3.0
            )
        }
    }

    // MARK: - v1.2.9 T5：SQL 聚合统计

    /// 3 路 SQL 聚合刷新侧栏统计 — 不 hydrate 完整 Card
    /// 1. typeCounts：GROUP BY type 聚合
    /// 2. tagCounts：JOIN cardTags + tags GROUP BY name
    /// 3. summaries：轻量字段（id/type/title/updatedAt/deletedAt）+ tags 批量查
    ///   性能：10k 卡全库 ~10ms（vs 修复前 hydrate 全库 ~100ms）
    func refreshStatsSQL() throws -> (
        summaries: [CardSummary],
        typeCounts: [CardType: Int],
        tagCounts: [(String, Int)]
    ) {
        // 1. typeCounts
        let typeRows = try db.dbWriter.read { grdb -> [(String, Int)] in
            try Row.fetchAll(grdb, sql: """
                SELECT type, COUNT(*) AS cnt FROM cards
                WHERE deletedAt IS NULL
                GROUP BY type
                """).map { row in
                let type: String = row["type"] ?? "free"
                let cnt: Int = row["cnt"] ?? 0
                return (type, cnt)
            }
        }
        var typeDict: [CardType: Int] = Dictionary(
            uniqueKeysWithValues: CardType.allCases.map { ($0, 0) }
        )
        for (raw, cnt) in typeRows {
            typeDict[CardType(rawValue: raw) ?? .free, default: 0] += cnt
        }

        // 2. tagCounts（JOIN cardTags + tags）
        let tagRows = try db.dbWriter.read { grdb -> [(String, Int)] in
            try Row.fetchAll(grdb, sql: """
                SELECT t.name, COUNT(*) AS cnt FROM tags t
                JOIN cardTags ct ON ct.tagId = t.id
                JOIN cards c ON c.id = ct.cardId
                WHERE c.deletedAt IS NULL
                GROUP BY t.name
                ORDER BY cnt DESC
                """).map { row in
                let name: String = row["name"] ?? ""
                let cnt: Int = row["cnt"] ?? 0
                return (name, cnt)
            }
        }

        // 3. summaries：仅查轻量字段，tags + fields 单独批量查
        //    v1.3.0：拼 searchText（title + tags + 字段值预拼接）
        let summaries = try db.dbWriter.read { grdb -> [CardSummary] in
            let recs = try Row.fetchAll(grdb, sql: """
                SELECT id, type, title, updatedAt, deletedAt FROM cards
                WHERE deletedAt IS NULL
                ORDER BY updatedAt DESC
                """)
            guard !recs.isEmpty else { return [] }

            // 批量查 tags（按 cardId 排序以利 CoW 修复模式）
            let ids = recs.map { $0["id"] as? String ?? "" }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(ids)

            let tagSQL = """
                SELECT ct.cardId, t.name FROM tags t
                JOIN cardTags ct ON ct.tagId = t.id
                WHERE ct.cardId IN (\(placeholders))
                ORDER BY ct.cardId, t.name ASC
                """
            let tagRows = try Row.fetchAll(grdb, sql: tagSQL, arguments: args)
            var tagsByCard: [String: [String]] = [:]
            var lastTagCardId: String? = nil
            for row in tagRows {
                guard let cardId: String = row["cardId"], let name: String = row["name"] else { continue }
                if cardId != lastTagCardId {
                    tagsByCard[cardId] = []
                    lastTagCardId = cardId
                }
                tagsByCard[cardId]!.append(name)
            }

            // v1.3.0：批量查 fields（仅 value，不查 name/order）用于拼 searchText
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

            return recs.map { row in
                let id: String = row["id"] ?? ""
                let type: String = row["type"] ?? "free"
                let title: String = row["title"] ?? ""
                let tags = tagsByCard[id] ?? []
                let fieldValues = fieldValuesByCard[id] ?? []
                let updatedAt = parseISO(row["updatedAt"] as? String ?? "") ?? Date()
                let deletedAt = (row["deletedAt"] as? String).flatMap(parseISO)
                // v1.3.0：title + tags + 字段值预拼接，tokenize 一次覆盖全部
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

        return (summaries: summaries, typeCounts: typeDict, tagCounts: tagRows)
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
    /// - 两边 ID 集合完全一致：仍要校验 mdVersion（v1.3.0）
    /// - mdVersion 落后：从 SQLite 重建对应 .md
    func reconcile() async throws {
        let mdIDs = try CardFileIO.listAllIDs()
        let dbIDs = try db.allIDs()

        // 1. v1.3.0：即便两边 ID 集合完全一致，也要校验 mdVersion
        //    （旧版 v1.2.9 在 ID 集合完全一致时直接 return，错过 .md 落后场景）
        // 2. .md 有但 SQLite 没有：从 .md 恢复
        let missingInDB = mdIDs.subtracting(dbIDs)
        if !missingInDB.isEmpty {
            // v1.3.0：reconcile 是 async，any DatabaseWriter 协议在 async 上下文中
            // 选 async 重载 → 加 await
            try await db.dbWriter.write { grdb in
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

        // 3. SQLite 有但 .md 没有：从 SQLite 重建 .md
        // v1.2.9 T5 优化：原 v1.3.0 P0-3 方案（一次 allCards + dictionary 查）
        // 仍要 hydrate 全库 fields/tags。改为精确 IN 查询：只 hydrate 缺失卡。
        let missingInMD = dbIDs.subtracting(mdIDs)
        if !missingInMD.isEmpty {
            let placeholders = missingInMD.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(missingInMD)
            do {
                // v1.3.0：async 上下文中加 await
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
                print("[KaJi.Repository] 对账时 IN 查询失败: \(error.localizedDescription)")
            }
        }

        // 4. v1.3.0：mdVersion 校验（终极一致性保障）
        //    即便两边 ID 集合完全一致，也要逐 .md 检查 frontmatter.mdVersion
        //    是否落后于 SQLite.mdVersion；落后则入队重写
        try checkMarkdownVersionConsistency()

        // 5. v1.2.9 T4：扫 .md_failures 目录，重试之前写入失败的 .md
        //    失败标记持久化到 .md_failures/<id>.failure，reconcile 启动时统一重试
        //    v1.3.0：改为走 MarkdownWriteQueue.retryFailures() 串行重试
        await MarkdownWriteQueue.shared.retryFailures()
    }

    /// v1.3.0：扫描所有 .md frontmatter 第一行的 mdVersion，与 SQLite 对比；
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
            print("[KaJi.Repository] checkMarkdownVersionConsistency 拉取 SQLite 失败: \(error.localizedDescription)")
            return
        }

        // 2. 遍历 cards/ 目录所有 .md；读 frontmatter 第一行的 mdVersion
        let mdDir: URL
        do {
            mdDir = try CardFileIO.cardsDir()
        } catch {
            print("[KaJi.Repository] checkMarkdownVersionConsistency 取 cardsDir 失败: \(error.localizedDescription)")
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
                // 老格式 .md（v1.2.9 之前）— 入队重写为 v1.3.0 格式
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

    /// 启动时跑一次：对账 + 清理超过保留天数的回收站卡
    /// v1.3.0：reconcile 改为 async（要走 MarkdownWriteQueue）
    func bootstrap(retentionDays: Int) async throws {
        try await reconcile()
        try db.purgeOldTrash(retentionDays: retentionDays)
    }

    // MARK: - 公共辅助

    /// DB 是否处于 in-memory 模式（fallback）— UI 层可以展示警告
    var isInMemory: Bool { db.isInMemory }

    // v1.3.0：ISO8601DateFormatter 是 thread-safe（Apple 文档：immutable state），
    // 删掉 OSAllocatedUnfairLock 包装 — 锁本身有性能开销，且无意义
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    // v1.2.9 T5 修复：fallback formatter 静态缓存，避免每次 parseISO 失败时新建
    nonisolated(unsafe) private static let isoFormatterFallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func iso8601(_ d: Date) -> String {
        Self.isoFormatter.string(from: d)
    }
    private func parseISO(_ s: String) -> Date? {
        if let d = Self.isoFormatter.date(from: s) { return d }
        return Self.isoFormatterFallback.date(from: s)
    }
}
