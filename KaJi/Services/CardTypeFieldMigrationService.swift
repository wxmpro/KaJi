//
//  CardTypeFieldMigrationService.swift
//  KaJi
//
//  改类型定义时，对该类型所有卡片批量迁移字段。
//  规则：卡片内容只认 fieldOrder，不认 fieldName。
//

import Foundation
import GRDB

/// 类型定义字段变更 → 该类型全部卡片批量迁移。
final class CardTypeFieldMigrationService: @unchecked Sendable {
    static let shared = CardTypeFieldMigrationService()

    private let db: AppDatabase

    init(db: AppDatabase = .shared) {
        self.db = db
    }

    /// 迁移某类型下所有卡片的字段结构。
    /// - typeId: 目标类型
    /// - newFieldNames: 新的内容字段名（不含标题/参考）
    /// - 返回被删除的字段内容快照，用于 undo
    func migrate(
        typeId: String,
        to newFieldNames: [String]
    ) throws -> MigrationSnapshot {
        return try db.dbWriter.write { grdb -> MigrationSnapshot in
            // 1. 读取该类型所有卡片（含回收站）
            let records = try CardRecord.fetchAll(grdb, sql: """
                SELECT * FROM cards WHERE type = ?
                """, arguments: [typeId])

            var deletedSnapshots: [DeletedFieldSnapshot] = []

            for rec in records {
                // 2. 读取该卡现有字段
                let oldFields = try CardFieldRecord.fetchAll(grdb, sql: """
                    SELECT * FROM cardFields WHERE cardId = ? ORDER BY fieldOrder
                    """, arguments: [rec.id])

                // 3. 新字段结构：标题 + newFieldNames + 参考
                let totalNewCount = newFieldNames.count + 1  // +1 为「参考」

                // 4. 删除超出新范围的字段，并记录快照
                for field in oldFields where field.fieldOrder >= totalNewCount {
                    deletedSnapshots.append(DeletedFieldSnapshot(
                        cardId: rec.id,
                        fieldName: field.fieldName ?? "",
                        fieldValue: field.fieldValue,
                        fieldOrder: field.fieldOrder
                    ))
                }

                try grdb.execute(sql: """
                    DELETE FROM cardFields WHERE cardId = ? AND fieldOrder >= ?
                    """, arguments: [rec.id, totalNewCount])

                // 5. 更新保留字段的 fieldName（按 Registry 新定义）
                for (order, name) in newFieldNames.enumerated() {
                    // 参考在最后一个 order
                    let fieldOrder = order
                    let fieldName = name
                    try grdb.execute(sql: """
                        INSERT INTO cardFields (cardId, fieldName, fieldValue, fieldOrder)
                        VALUES (?, ?, COALESCE((SELECT fieldValue FROM cardFields WHERE cardId = ? AND fieldOrder = ?), ''), ?)
                        ON CONFLICT(cardId, fieldOrder) DO UPDATE SET fieldName = excluded.fieldName
                        """, arguments: [rec.id, fieldName, rec.id, fieldOrder, fieldOrder])
                }

                // 6. 确保「参考」字段存在
                let referenceOrder = newFieldNames.count
                try grdb.execute(sql: """
                    INSERT INTO cardFields (cardId, fieldName, fieldValue, fieldOrder)
                    VALUES (?, '参考', COALESCE((SELECT fieldValue FROM cardFields WHERE cardId = ? AND fieldOrder = ?), ''), ?)
                    ON CONFLICT(cardId, fieldOrder) DO UPDATE SET fieldName = '参考'
                    """, arguments: [rec.id, rec.id, referenceOrder, referenceOrder])

                // 7. 更新卡片 updatedAt 和 mdVersion
                let now = ISO8601DateFormatter().string(from: Date())
                try grdb.execute(sql: """
                    UPDATE cards SET updatedAt = ?, mdVersion = mdVersion + 1 WHERE id = ?
                    """, arguments: [now, rec.id])
            }

            return MigrationSnapshot(deletedFields: deletedSnapshots)
        }
    }

    /// 把卡片字段结构改为「其他类型」（5 个字段：字段 1~5）。
    /// 用于删除自定义类型时选择「转为其他类型」。
    func migrateToFallback(typeId: String) throws {
        let fallbackFieldNames = CardTypeRegistry.shared.fallback.fieldNames
        _ = try migrate(typeId: typeId, to: fallbackFieldNames)
        // 同时更新卡片 type 为 fallback id（由 PersistenceService 已做）
    }

    /// 根据快照恢复被删除的字段。
    /// 用于 undo「减少字段」操作。
    func restoreDeletedFields(_ snapshot: MigrationSnapshot) throws {
        guard !snapshot.isEmpty else { return }
        try db.dbWriter.write { grdb in
            for field in snapshot.deletedFields {
                var rec = CardFieldRecord(
                    cardId: field.cardId,
                    fieldName: field.fieldName,
                    fieldValue: field.fieldValue,
                    fieldOrder: field.fieldOrder
                )
                try rec.insert(grdb)

                // 更新卡片 updatedAt 和 mdVersion
                let now = ISO8601DateFormatter().string(from: Date())
                try grdb.execute(sql: """
                    UPDATE cards SET updatedAt = ?, mdVersion = mdVersion + 1 WHERE id = ?
                    """, arguments: [now, field.cardId])
            }
        }
    }
}

// MARK: - 快照模型

struct DeletedFieldSnapshot: Codable {
    let cardId: String
    let fieldName: String
    let fieldValue: String
    let fieldOrder: Int
}

struct MigrationSnapshot: Codable {
    let deletedFields: [DeletedFieldSnapshot]

    var isEmpty: Bool { deletedFields.isEmpty }
}
