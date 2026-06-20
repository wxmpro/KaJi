//
//  AppDatabase.swift
//  KaJi
//
//  GRDB.swift 数据库管理。
//  4 张表：
//    1. cards          — 主表
//    2. cardFields     — EAV 模式字段
//    3. tags           — 标签
//    4. cardTags       — 卡-标签 M:N
//  搜索统一走 StatsState.cachedSummaries 内存 filter，不再维护 FTS5 虚拟表。
//
//  线程模型：
//    - 单一 DatabasePool（写串行；读并发）
//    - UI 层只通过 Repository 访问，UI 不直接动 Database
//

import Foundation
import os
@preconcurrency import GRDB

final class AppDatabase: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.kaji.app", category: "appdatabase")

    /// 单例 — 用 try-catch + in-memory fallback 避免 fatalError 触发 Swift 6 assertion
    /// （之前 `static let ... fatalError` 在 Swift 6 strict concurrency 下会让 runtime 触发
    ///   `_assertionFailure` EXC_BREAKPOINT，比单纯 crash 更难看）
    static let shared: AppDatabase = {
        do { return try AppDatabase(useInMemory: false) }
        catch let fileError {
            // Fallback: in-memory Queue（不是 Pool — in-memory Pool 不支持 WAL 模式）
            // 数据不持久化但 App 不崩
            log.error("文件 DB 失败: \(fileError.localizedDescription, privacy: .public). 用 in-memory fallback.")
            do { return try AppDatabase(useInMemory: true) }
            catch let memoryError {
                fatalError("无法创建数据库（包括 in-memory fallback）: \(memoryError)")
            }
        }
    }()

    /// 统一 DB 访问 — Pool（文件）或 Queue（in-memory）共用一个协议
    let dbWriter: any DatabaseWriter
    let isInMemory: Bool

    private init(useInMemory: Bool) throws {
        if useInMemory {
            var config = Configuration()
            config.label = "KaJi.DB.InMemory"
            // DatabaseQueue — in-memory 必须用 Queue，Pool 强制 WAL
            dbWriter = try DatabaseQueue(path: ":memory:", configuration: config)
            isInMemory = true
        } else {
            let dbURL = try AppDatabase.dbURL()
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var config = Configuration()
            config.label = "KaJi.DB"
            // 跨进程并发兜底 — 第二进程等 5s 不立即失败
            // GRDB IMMEDIATE 事务 + busy_timeout 协同，避免 SQLITE_BUSY 直接抛错
            config.busyMode = .timeout(5)
            // 连接级 PRAGMA 调优。仅文件 DB；每个 Pool 连接打开时执行一次。
            // WAL 模式下这些都是安全的纯性能项。
            config.prepareDatabase { db in
                // WAL 下 NORMAL 不牺牲崩溃一致性（仅极端断电下回退到最近 checkpoint），
                // 但省掉每次提交的 fsync，写入显著更快。
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                // 页缓存 20MB（负数 = KB）。705 卡量级整库可常驻内存，读放大趋近 0。
                try db.execute(sql: "PRAGMA cache_size = -20000")
                // 256MB 内存映射 I/O，读路径绕过 read() 系统调用，降低延迟。
                try db.execute(sql: "PRAGMA mmap_size = 268435456")
            }
            dbWriter = try DatabasePool(path: dbURL.path, configuration: config)
            isInMemory = false
        }
        try migrator.migrate(dbWriter)
    }

    /// 数据库文件路径
    static func dbURL() throws -> URL {
        try CardFileIO.dataRoot().appendingPathComponent("index.sqlite")
    }

    // MARK: - 迁移

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1.0_initial") { db in
            // 1. cards
            try db.create(table: "cards") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
                t.column("deletedAt", .text)                              // 回收站时间
                t.column("filePath", .text).notNull()                     // .md 绝对路径
                t.column("fileMtime", .integer)
                t.column("fileHash", .text)
                t.column("fileSize", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_cards_type", on: "cards", columns: ["type"])
            try db.create(index: "idx_cards_createdAt", on: "cards", columns: ["createdAt"])
            try db.create(index: "idx_cards_deletedAt", on: "cards", columns: ["deletedAt"])

            // 2. cardFields (EAV)
            try db.create(table: "cardFields") { t in
                t.column("cardId", .text).notNull()
                    .references("cards", onDelete: .cascade)
                t.column("fieldName", .text).notNull()
                t.column("fieldValue", .text).notNull().defaults(to: "")
                t.column("fieldOrder", .integer).notNull().defaults(to: 0)
                t.primaryKey(["cardId", "fieldName"])
            }
            try db.create(index: "idx_cardFields_fieldName", on: "cardFields", columns: ["fieldName"])

            // 3. tags
            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }
            try db.create(index: "idx_tags_name", on: "tags", columns: ["name"])

            // 4. cardTags (M:N)
            try db.create(table: "cardTags") { t in
                t.column("cardId", .text).notNull()
                    .references("cards", onDelete: .cascade)
                t.column("tagId", .integer).notNull()
                    .references("tags", onDelete: .cascade)
                t.primaryKey(["cardId", "tagId"])
            }
        }

        m.registerMigration("v1.1_drop_fts5") { db in
            // 删除旧版可能存在的 cardsFts 虚拟表（搜索已改走内存 filter）
            try db.execute(sql: "DROP TABLE IF EXISTS cardsFts")
        }

        // mdVersion：每次 SQLite 写 +1；.md 写盘时把当前 mdVersion 写进 frontmatter；
        // reconcile 启动期对比 SQLite.mdVersion 与 .md frontmatter.mdVersion 检测落后
        m.registerMigration("v1.3.0_add_mdVersion") { db in
            try db.alter(table: "cards") { t in
                t.add(column: "mdVersion", .integer).notNull().defaults(to: 0)
            }
        }

        // updatedAt 索引：refreshStatsSQL 与列表默认序均按 `ORDER BY updatedAt DESC`，
        // 补索引后走索引顺序扫描，避免全表扫描 + 临时 B-tree 排序
        m.registerMigration("v1.4.2_add_updatedAt_index") { db in
            try db.create(
                index: "idx_cards_updatedAt",
                on: "cards",
                columns: ["updatedAt"],
                ifNotExists: true
            )
        }

        return m
    }

    // MARK: - 启动时清理：N 天前的回收站卡彻底删除

    /// 启动时调用一次：删除超过 retentionDays 天的回收站卡
    /// - Parameter retentionDays: 回收站保留天数；≤0 表示永不自动清理
    func purgeOldTrash(retentionDays: Int) async throws {
        guard retentionDays > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            throw DatabaseError.trashCutoffDateUnavailable
        }
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)

        // 1. 先删 SQLite（在写事务内）；cardFields / cardTags 由级联自动清理
        let idsToPurge = try await dbWriter.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM cards WHERE deletedAt IS NOT NULL AND deletedAt < ?
                """, arguments: [cutoffStr])
            try db.execute(sql: """
                DELETE FROM cards WHERE deletedAt IS NOT NULL AND deletedAt < ?
                """, arguments: [cutoffStr])
            return ids
        }

        // 2. SQLite 提交成功后，并发删 .md（限流 8 并发）
        await withTaskGroup(of: Void.self) { group in
            var iterator = idsToPurge.makeIterator()
            let maxConcurrent = 8
            var inFlight = 0

            func enqueueNext() {
                guard let id = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    try? CardFileIO.delete(id: id)
                }
            }

            for _ in 0..<min(maxConcurrent, idsToPurge.count) { enqueueNext() }

            while inFlight > 0 {
                await group.next()
                inFlight -= 1
                enqueueNext()
            }
        }
    }

    // MARK: - 全部卡 id（用于 ID 生成器查重）

    func allIDs() throws -> Set<String> {
        try dbWriter.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT id FROM cards")
            return Set(rows)
        }
    }
}
