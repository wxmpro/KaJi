//
//  CardTypeRecords.swift
//  KaJi
//
//  自定义卡片类型相关 GRDB record。
//

import Foundation
@preconcurrency import GRDB

/// cardTypeDefs 表：类型定义（内置 override + 自定义类型 + 已删除但回收站仍有卡的类型）
struct CardTypeDefRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "cardTypeDefs"

    var id: String
    var name: String
    var colorRaw: String
    var sortOrder: Int
    var createdAt: String
    var isDeleted: Bool

    init(
        id: String,
        name: String,
        colorRaw: String,
        sortOrder: Int,
        createdAt: String,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorRaw = colorRaw
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.isDeleted = isDeleted
    }
}

/// cardTypeFields 表：类型字段定义
struct CardTypeFieldRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "cardTypeFields"

    var typeId: String
    var fieldName: String
    var fieldOrder: Int
}

/// typeOrder 表：全局顺序
struct TypeOrderRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "typeOrder"

    var orderIndex: Int
    var typeId: String
}

/// typeVisibility 表：侧栏展示集合
struct TypeVisibilityRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "typeVisibility"

    var typeId: String
    var isVisible: Bool

    enum CodingKeys: String, CodingKey {
        case typeId
        case isVisible
    }

    init(typeId: String, isVisible: Bool) {
        self.typeId = typeId
        self.isVisible = isVisible
    }
}

// GRDB 需要 Bool 与 INTEGER 的转换
extension TypeVisibilityRecord {
    init(row: Row) {
        typeId = row["typeId"]
        isVisible = row["isVisible"]
    }
}

// 让 CardFieldRecord 适应新主键 (cardId, fieldOrder)，fieldName 可空
// 注：CardFieldRecord 定义在 CardRecord.swift，此处不重复定义。
