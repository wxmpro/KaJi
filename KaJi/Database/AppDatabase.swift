//
//  AppDatabase.swift
//  KaJi
//
//  GRDB.swift 数据库管理。
//  5 张表（按数据库设计文档）：
//    1. cards          — 主表
//    2. cardFields     — EAV 模式字段
//    3. tags           — 标签
//    4. cardTags       — 卡-标签 M:N
//  搜索统一走 StatsState.cachedCards 内存 filter，不再维护 FTS5 虚拟表。
//
//  + 1 张 v1.0 回收站表实现：
//    deletedCards     — deletedAt 非空的卡（启动时按设置保留天数清理）
//
//  v1.0 简化：deletedCards 不新建表，复用 cards 表 + deletedAt 字段。
//  清理策略：启动时 `DELETE FROM cards WHERE deletedAt IS NOT NULL AND deletedAt < ?`
//
//  线程模型：
//    - 单一 DatabasePool（写串行；读并发）
//    - UI 层只通过 Repository 访问，UI 不直接动 Database
//

import Foundation
@preconcurrency import GRDB

final class AppDatabase: @unchecked Sendable {

    /// 单例 — 用 try-catch + in-memory fallback 避免 fatalError 触发 Swift 6 assertion
    /// （之前 `static let ... fatalError` 在 Swift 6 strict concurrency 下会让 runtime 触发
    ///   `_assertionFailure` EXC_BREAKPOINT，比单纯 crash 更难看）
    static let shared: AppDatabase = {
        do { return try AppDatabase(useInMemory: false) }
        catch let fileError {
            // Fallback: in-memory Queue（不是 Pool — in-memory Pool 不支持 WAL 模式）
            // 数据不持久化但 App 不崩
            print("[KaJi.DB] 文件 DB 失败: \(fileError). 用 in-memory fallback.")
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
            let dbURL = AppDatabase.dbURL
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var config = Configuration()
            config.label = "KaJi.DB"
            dbWriter = try DatabasePool(path: dbURL.path, configuration: config)
            isInMemory = false
        }
        try migrator.migrate(dbWriter)
    }

    static var dbURL: URL {
        CardFileIO.dataRoot.appendingPathComponent("index.sqlite")
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
            // H-1：搜索统一走 AppState.cachedCards 内存 filter，不再维护 FTS5 索引。
            // 删除旧版可能存在的 cardsFts 虚拟表，释放空间并避免歧义。
            try db.execute(sql: "DROP TABLE IF EXISTS cardsFts")
        }

        return m
    }

    // MARK: - 启动时清理：N 天前的回收站卡彻底删除

    /// 启动时调用一次：删除超过 retentionDays 天的回收站卡
    /// - Parameter retentionDays: 回收站保留天数；≤0 表示永不自动清理
    func purgeOldTrash(retentionDays: Int) throws {
        guard retentionDays > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            throw NSError(domain: "AppDatabase", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法计算回收站清理截止日期"])
        }
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)

        // 1. 先删 SQLite（在写事务内）；cardFields / cardTags 由级联自动清理
        let idsToPurge = try dbWriter.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM cards WHERE deletedAt IS NOT NULL AND deletedAt < ?
                """, arguments: [cutoffStr])
            try db.execute(sql: """
                DELETE FROM cards WHERE deletedAt IS NOT NULL AND deletedAt < ?
                """, arguments: [cutoffStr])
            return ids
        }

        // 2. SQLite 提交成功后，再删 .md
        for id in idsToPurge {
            try? CardFileIO.delete(id: id)
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
