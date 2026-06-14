//
//  CardField.swift
//  KaJi
//
//  卡片的一个字段（label + value + 顺序）。
//  EAV 模式：一张卡可有 0..N 个 CardField，按 fieldOrder 排序。
//

import Foundation

struct CardField: Identifiable, Hashable, Codable {
    var id: String { "\(cardId)#\(fieldName)" }

    let cardId: String         // 17 位唯一编码 — 外键 → Card.id
    let fieldName: String      // 字段名，如 "定义" / "解释" / "参考"
    var fieldValue: String     // 字段值
    var fieldOrder: Int        // 同卡内顺序（0, 1, 2, ...）

    init(cardId: String, fieldName: String, fieldValue: String = "", fieldOrder: Int = 0) {
        self.cardId = cardId
        self.fieldName = fieldName
        self.fieldValue = fieldValue
        self.fieldOrder = fieldOrder
    }
}
