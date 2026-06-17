//
//  Card.swift
//  KaJi
//
//  一张卡片。
//  - id：17 位纯数字（YYYYMMDDHHMMSS + 3 位毫秒），保证全局唯一
//  - type：CardType（12 种内置之一，v1.2.9 T7 注释修正 — 原本误写 11 种）
//  - title：标题（≤ 30 字符；空时自动取首字段前 30 字）
//  - tags：[String]，≤ 5 个，每个 ≤ 10 字符
//  - fields：[CardField]，EAV 模式
//  - createdAt / updatedAt：ISO8601
//  - deletedAt：进回收站时间（nil = 在主库；非 nil = 在回收站）
//
//  v1.0 不支持双链 / 文件夹；v1.1 再加。
//

import Foundation

struct Card: Identifiable, Hashable, Codable {
    let id: String                // 17 位
    var type: String              // CardType.rawValue（详情态不可改；编辑态可改）
    var title: String             // 标题
    var tags: [String]            // 标签数组
    var fields: [CardField]       // EAV 字段集合
    let createdAt: Date           // 创建时间
    var updatedAt: Date           // 最后修改时间
    var deletedAt: Date?          // 回收站时间
    // v1.3.0：每次 SQLite 写 +1；MarkdownWriteQueue 用以检测 .md 是否需要重写
    var mdVersion: Int64 = 0

    // MARK: - 派生

    var cardType: CardType { CardType(rawValue: type) ?? .free }

    /// 按 fieldOrder 排序后的字段（UI 渲染顺序）
    var orderedFields: [CardField] { fields.sorted { $0.fieldOrder < $1.fieldOrder } }

    /// 取指定字段名的值（不区分大小写严格匹配）
    func value(ofField named: String) -> String {
        fields.first { $0.fieldName == named }?.fieldValue ?? ""
    }

    /// 卡片"内容字符数" — 按 PRD V2 第 2 条：含标题、所有字段名+字段值、标签；不含唯一编码
    /// 计算 = sum(label.length + value.length) + sum(tag.length)
    /// - 注意：字段名（label）也计入 — 你的修正："字段内容 = 字段名 + 字段值"
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

    /// v1.3.4 PATCH：卡片是否内容为空（用于空卡自动删除判定）
    /// 复用 `CardTypeChangeService.currentCardHasContent` 的 trim+isEmpty 模式并取反。
    /// 判定标准：title trim 空 + tags 空 + 全部 fieldValue trim 空。
    /// 注意：单纯 `title.isEmpty` 不够，因为用户可能输入全空格。
    var isEmpty: Bool {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if !tags.isEmpty { return false }
        return fields.allSatisfy {
            $0.fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// v1.4.0：判断是否为占位卡
    var isPlaceholder: Bool {
        id == Card.placeholderID
    }

    // MARK: - 工厂方法

    /// 构造一张新卡（不写库）
    static func new(
        type: CardType,
        id: String,
        title: String = "",
        tags: [String] = [],
        fields: [String: String] = [:]
    ) -> Card {
        let now = Date()
        let cardFields = type.fields.enumerated().map { idx, name in
            CardField(cardId: id, fieldName: name, fieldValue: fields[name] ?? "", fieldOrder: idx)
        }
        return Card(
            id: id, type: type.rawValue, title: title, tags: tags,
            fields: cardFields,
            createdAt: now, updatedAt: now, deletedAt: nil
        )
    }
}

// MARK: - v1.4.0：占位卡

extension Card {
    /// v1.4.0：占位卡 ID（17 位 0，UI 永远不显示）
    static let placeholderID = String(repeating: "0", count: 17)

    /// v1.4.0：占位卡（无 UUID，未持久化）。UI 永远不显示 placeholder 的 ID。
    /// type 默认 .free；可在 commitDraft 时根据 draft.cardType 调整
    static let placeholder = Card(
        id: placeholderID,
        type: CardType.free.rawValue,
        title: "",
        tags: [],
        fields: [],
        createdAt: .distantPast,
        updatedAt: .distantPast,
        deletedAt: nil
    )
}

// MARK: - 便捷：JSON 编码

extension Card {
    func toJSON() throws -> Data { try JSONEncoder().encode(self) }
    static func fromJSON(_ data: Data) throws -> Card { try JSONDecoder().decode(Card.self, from: data) }
}