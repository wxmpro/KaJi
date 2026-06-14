//
//  CardRecord.swift
//  KaJi
//
//  GRDB record — 数据库行映射。
//  与 Model Card 解耦：Record 走数据库，Card 走 UI。
//  Repository 负责两者转换。
//

import Foundation
import GRDB

struct CardRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "cards"

    var id: String
    var type: String
    var title: String
    var createdAt: String      // ISO8601
    var updatedAt: String
    var deletedAt: String?
    var filePath: String
    var fileMtime: Int?
    var fileHash: String?
    var fileSize: Int
}

struct CardFieldRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "cardFields"

    var cardId: String
    var fieldName: String
    var fieldValue: String
    var fieldOrder: Int
}

struct TagRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tags"

    var id: Int64?
    var name: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct CardTagRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cardTags"

    var cardId: String
    var tagId: Int64
}
