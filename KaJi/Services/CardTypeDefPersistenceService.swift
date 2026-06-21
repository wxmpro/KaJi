//
//  CardTypeDefPersistenceService.swift
//  KaJi
//
//  卡片类型定义的持久化：新建 / 编辑 / 删除自定义类型，保存内置 override，恢复默认。
//

import Foundation
import GRDB

/// 自定义卡片类型的持久化服务。
/// 所有写操作成功后必须调用 `CardTypeRegistry.shared.reload()` 让 UI 生效。
final class CardTypeDefPersistenceService: @unchecked Sendable {
    static let shared = CardTypeDefPersistenceService()

    private let db: AppDatabase

    init(db: AppDatabase = .shared) {
        self.db = db
    }

    // MARK: - 查询

    /// 当前已有卡片数（按 typeId）
    func cardCount(for typeId: String) throws -> Int {
        try db.dbWriter.read { grdb in
            try Int.fetchOne(grdb, sql: """
                SELECT COUNT(*) FROM cards
                WHERE type = ? AND deletedAt IS NULL
                """, arguments: [typeId]) ?? 0
        }
    }

    /// 显示名是否已被占用（内置/自定义/已删除但回收站仍有卡的类型一起查，不含自身）
    func isNameTaken(_ name: String, excluding typeId: String?) throws -> Bool {
        try db.dbWriter.read { grdb in
            let records = try CardTypeDefRecord.fetchAll(grdb)

            // 1. 当前存在的类型定义
            if records.contains(where: { $0.name == name && !$0.isDeleted && $0.id != typeId }) {
                return true
            }

            // 2. 已删除但回收站仍有卡片的类型：仍占用显示名
            for def in records where def.isDeleted && def.id != typeId && def.name == name {
                let count = try Int.fetchOne(grdb, sql: """
                    SELECT COUNT(*) FROM cards WHERE type = ? AND deletedAt IS NOT NULL
                    """, arguments: [def.id]) ?? 0
                if count > 0 {
                    return true
                }
            }

            return false
        }
    }

    // MARK: - 保存全局顺序

    /// 保存类型的全局显示顺序。
    /// - orderedIds: 按顺序排列的全部 typeId（含内置、自定义、fallback）
    func saveTypeOrder(_ orderedIds: [String]) throws {
        try db.dbWriter.write { grdb in
            try TypeOrderRecord.deleteAll(grdb)
            for (index, typeId) in orderedIds.enumerated() {
                var rec = TypeOrderRecord(orderIndex: index, typeId: typeId)
                try rec.insert(grdb)
            }
        }
    }

    // MARK: - 保存可见性

    /// 设置单个类型的侧栏可见性。
    func setTypeVisible(_ typeId: String, isVisible: Bool) throws {
        try db.dbWriter.write { grdb in
            var rec = TypeVisibilityRecord(typeId: typeId, isVisible: isVisible)
            try rec.save(grdb)
        }
    }

    // MARK: - 保存自定义类型

    /// 新建或更新自定义类型。
    /// - 新建时分配 custom:UUID
    /// - 更新时同步字段定义（调用方需自行决定是否迁移已有卡片）
    @discardableResult
    func saveCustomType(
        id: String? = nil,
        name: String,
        colorRaw: String,
        fieldNames: [String]
    ) throws -> String {
        let typeId = id ?? "custom:\(UUID().uuidString)"
        let now = ISO8601DateFormatter().string(from: Date())

        try db.dbWriter.write { grdb in
            // 1. 保存/更新类型主记录
            var defRec = CardTypeDefRecord(
                id: typeId,
                name: name,
                colorRaw: colorRaw,
                sortOrder: 0,
                createdAt: now,
                isDeleted: false
            )
            try defRec.save(grdb)

            // 2. 删除旧字段定义
            try CardTypeFieldRecord
                .filter(Column("typeId") == typeId)
                .deleteAll(grdb)

            // 3. 写入新字段定义
            for (index, fieldName) in fieldNames.enumerated() {
                var fieldRec = CardTypeFieldRecord(
                    typeId: typeId,
                    fieldName: fieldName,
                    fieldOrder: index
                )
                try fieldRec.insert(grdb)
            }

            // 4. 新类型：追加到顺序表末尾，默认不可见
            if id == nil {
                let maxIndex = (try TypeOrderRecord.fetchAll(grdb).map { $0.orderIndex }.max()) ?? -1
                var orderRec = TypeOrderRecord(orderIndex: maxIndex + 1, typeId: typeId)
                try orderRec.insert(grdb)

                var visibilityRec = TypeVisibilityRecord(typeId: typeId, isVisible: false)
                try visibilityRec.insert(grdb)
            }
        }

        return typeId
    }

    // MARK: - 保存内置 override

    /// 保存内置类型的用户覆盖（改名 / 改字段 / 改色）
    func saveBuiltinOverride(
        id: String,
        name: String,
        colorRaw: String,
        fieldNames: [String]
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())

        try db.dbWriter.write { grdb in
            var defRec = CardTypeDefRecord(
                id: id,
                name: name,
                colorRaw: colorRaw,
                sortOrder: 0,
                createdAt: now,
                isDeleted: false
            )
            try defRec.save(grdb)

            try CardTypeFieldRecord
                .filter(Column("typeId") == id)
                .deleteAll(grdb)

            for (index, fieldName) in fieldNames.enumerated() {
                var fieldRec = CardTypeFieldRecord(
                    typeId: id,
                    fieldName: fieldName,
                    fieldOrder: index
                )
                try fieldRec.insert(grdb)
            }
        }
    }

    // MARK: - 恢复默认

    /// 删除内置类型的 override 记录，恢复出厂默认
    func restoreBuiltinDefault(id: String) throws {
        try db.dbWriter.write { grdb in
            try CardTypeDefRecord.deleteOne(grdb, key: id)
            try CardTypeFieldRecord
                .filter(Column("typeId") == id)
                .deleteAll(grdb)
        }
    }

    // MARK: - 删除自定义类型

    /// 删除自定义类型。
    /// - preserveCards: true → 该类型下卡片转为「其他类型」；false → 连卡一起软删除
    /// - 返回被影响的卡片 id 集合（用于 UI 提示或刷新）
    @discardableResult
    func deleteCustomType(id: String, preserveCards: Bool) throws -> [String] {
        try db.dbWriter.write { grdb -> [String] in
            let cardIDs = try String.fetchAll(grdb, sql: """
                SELECT id FROM cards WHERE type = ?
                """, arguments: [id])

            if preserveCards {
                // 转为「其他类型」：卡片不再引用原 typeId，可彻底删除类型定义
                try grdb.execute(sql: """
                    UPDATE cards SET type = ? WHERE type = ?
                    """, arguments: ["builtin:fallback", id])
                try CardTypeDefRecord.deleteOne(grdb, key: id)
                try CardTypeFieldRecord
                    .filter(Column("typeId") == id)
                    .deleteAll(grdb)
            } else {
                // 软删除卡片：原 typeId 仍被回收站卡片引用，保留定义并标记为已删除
                let now = ISO8601DateFormatter().string(from: Date())
                try grdb.execute(sql: """
                    UPDATE cards SET deletedAt = ?, updatedAt = ? WHERE type = ? AND deletedAt IS NULL
                    """, arguments: [now, now, id])

                if var defRec = try CardTypeDefRecord.fetchOne(grdb, key: id) {
                    defRec.isDeleted = true
                    try defRec.update(grdb)
                }
                // 字段定义保留，以便 undo/恢复或历史显示名查询
            }

            try TypeOrderRecord.deleteOne(grdb, key: id)
            try TypeVisibilityRecord.deleteOne(grdb, key: id)

            return cardIDs
        }
    }
}
