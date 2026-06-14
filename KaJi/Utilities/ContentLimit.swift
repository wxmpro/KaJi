//
//  ContentLimit.swift
//  KaJi
//
//  3500 字符检测 — 按 PRD V2 第 2 条 + 你的修正：
//  "字段内容 = 字段名 + 字段值，标签计入，唯一编码不计"
//
//  计算 = sum(label.length + value.length) + sum(tag.length) + title.length
//
//  Note: Swift 的 String.count 是 Unicode 标量数（即"字符数"），符合 PRD "3500 字符"。
//

import Foundation

enum ContentLimit {
    /// 3500 — 写死；v1.0 不可配置（PRD V2 #11）
    static let maxChars: Int = 3500

    /// 标题上限
    static let maxTitleChars: Int = 30

    /// 单标签上限
    static let maxTagChars: Int = 10

    /// 标签数量上限
    static let maxTagCount: Int = 5

    /// 一张卡的总字符数
    static func count(card: Card) -> Int { card.contentCharCount }

    /// 是否超限
    static func isOverLimit(card: Card) -> Bool { count(card: card) > maxChars }

    /// 截断到上限（保留前 N 字符；标签不截断，但"超长"标签由上层拒绝添加）
    /// - Returns: 截断后的 Card
    static func truncate(_ card: Card) -> Card {
        var c = card
        let over = count(card: c) - maxChars
        guard over > 0 else { return c }

        // 优先截断最后一个有内容的字段（保留前 N-1 个字段完整）
        let ordered = c.orderedFields
        for i in (0..<ordered.count).reversed() {
            let f = ordered[i]
            if !f.fieldValue.isEmpty {
                let trimmed = String(f.fieldValue.dropLast(min(over, f.fieldValue.count)))
                if let idx = c.fields.firstIndex(where: { $0.fieldName == f.fieldName && $0.fieldOrder == f.fieldOrder }) {
                    c.fields[idx].fieldValue = trimmed
                }
                if count(card: c) <= maxChars { break }
            }
        }
        return c
    }
}
