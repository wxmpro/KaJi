//
//  Card.swift
//  KaJi
//
//  一张卡片。
//  - id：17 位纯数字（YYYYMMDDHHMMSS + 3 位毫秒），保证全局唯一
//  - type：CardType（12 种内置之一）
//  - title：标题（≤ 30 字符；空时自动取首字段前 30 字）
//  - tags：[String]，≤ 5 个，每个 ≤ 10 字符
//  - fields：[CardField]，EAV 模式
//  - createdAt / updatedAt：ISO8601
//  - deletedAt：进回收站时间（nil = 在主库；非 nil = 在回收站）
//

import Foundation
import SwiftUI

struct Card: Identifiable, Hashable, Codable {
    let id: String                // 17 位
    var type: String              // CardType.rawValue（详情态不可改；编辑态可改）
    var title: String             // 标题
    var tags: [String]            // 标签数组
    var fields: [CardField]       // EAV 字段集合
    let createdAt: Date           // 创建时间
    var updatedAt: Date           // 最后修改时间
    var deletedAt: Date?          // 回收站时间
    /// 每次 SQLite 写 +1；MarkdownWriteQueue 用以检测 .md 是否需要重写
    var mdVersion: Int64 = 0

    // MARK: - 派生

    /// 当前类型定义（基于 Registry）
    var cardTypeDef: CardTypeDef { CardTypeRegistry.shared.def(for: type) }

    /// 按 fieldOrder 排序后的字段（UI 渲染顺序）
    var orderedFields: [CardField] { fields.sorted { $0.fieldOrder < $1.fieldOrder } }

    /// 取指定字段名的值。
    /// 阶段2起按 fieldOrder 对齐类型定义查找，不直接依赖 cardFields.fieldName。
    func value(ofField named: String) -> String {
        let typeDef = CardTypeRegistry.shared.def(for: type)
        guard let order = typeDef.allFields.firstIndex(of: named) else { return "" }
        return fields.first { $0.fieldOrder == order }?.fieldValue ?? ""
    }

    /// 卡片"内容字符数" — 含标题、所有字段名+字段值、标签；不含唯一编码
    var contentCharCount: Int {
        var total = title.count
        for f in fields {
            total += f.fieldName.count
            total += f.fieldValue.count
        }
        for t in tags {
            total += t.count
        }
        return total
    }

    /// 14 位显示用编码（去掉 3 位毫秒）
    var displayID: String { String(id.prefix(14)) }

    /// 卡片是否内容为空（用于空卡自动删除判定）
    /// 判定标准：title trim 空 + tags 空 + 全部 fieldValue trim 空
    var isEmpty: Bool {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if !tags.isEmpty { return false }
        return fields.allSatisfy {
            $0.fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 判断是否为占位卡
    var isPlaceholder: Bool {
        id == Card.placeholderID
    }

    // MARK: - 工厂方法

    /// 构造一张新卡（不写库）
    static func new(
        typeId: String,
        id: String,
        title: String = "",
        tags: [String] = [],
        fields: [String: String] = [:]
    ) -> Card {
        let now = Date()
        let fieldNames = CardTypeRegistry.shared.allFields(for: typeId)
        let cardFields = fieldNames.enumerated().map { idx, name in
            CardField(cardId: id, fieldName: name, fieldValue: fields[name] ?? "", fieldOrder: idx)
        }
        return Card(
            id: id, type: typeId, title: title, tags: tags,
            fields: cardFields,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
    }
}

// MARK: - 占位卡

extension Card {
    /// 占位卡 ID（17 位 0，UI 永远不显示）
    static let placeholderID = String(repeating: "0", count: 17)

    /// 占位卡（无 UUID，未持久化）。UI 永远不显示 placeholder 的 ID。
    /// type 默认自由卡；可在 commitDraft 时根据 draft.cardTypeID 调整
    static let placeholder = Card(
        id: placeholderID,
        type: "自由卡",
        title: "",
        tags: [],
        fields: [],
        createdAt: .distantPast,
        updatedAt: .distantPast,
        deletedAt: nil
    )
}

// MARK: - JSON 编码便捷

extension Card {
    func toJSON() throws -> Data { try JSONEncoder().encode(self) }
    static func fromJSON(_ data: Data) throws -> Card { try JSONDecoder().decode(Card.self, from: data) }
}