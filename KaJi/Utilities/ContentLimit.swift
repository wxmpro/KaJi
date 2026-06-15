//
//  ContentLimit.swift
//  KaJi
//
//  3500 字符限制 — 按 PRD V2 第 2 条 + 你的修正：
//  "字段内容 = 字段名 + 字段值，标签计入，唯一编码不计"
//
//  计算 = sum(label.length + value.length) + sum(tag.length) + title.length
//
//  修复策略（按信息重要性的倒序）：
//  1. 先截断字段值（保留字段名，只丢内容）
//  2. 仍超：移除标签（从后往前）
//  3. 最后：截断标题
//

import Foundation

enum ContentLimit {
    /// 3500 — 写死；v1.0 不可配置（PRD V2 #11）
    static let maxChars: Int = 3500

    /// 一张卡的总字符数
    static func count(card: Card) -> Int { card.contentCharCount }

    /// 是否超限
    static func isOverLimit(card: Card) -> Bool { count(card: card) > maxChars }

    /// 修复超限卡片，返回符合 3500 字符限制的卡片
    /// - Returns: 修复后的 Card（未超限则原样返回）
    static func fix(_ card: Card) -> Card {
        var c = card
        var excess = count(card: c) - maxChars
        guard excess > 0 else { return c }

        // 1. 优先截断字段值（保留字段结构）
        c = truncateFields(c, excess: &excess)
        if excess <= 0 { return c }

        // 2. 仍超限：移除标签
        c = truncateTags(c, excess: &excess)
        if excess <= 0 { return c }

        // 3. 最后手段：截断标题
        c = truncateTitle(c, excess: excess)
        return c
    }

    /// 旧名保留，与新 `fix` 语义一致
    static func truncate(_ card: Card) -> Card { fix(card) }

    // MARK: - 内部策略

    /// 从最后一个有内容的字段开始截断值，直到空间足够或没有可截内容
    private static func truncateFields(_ card: Card, excess: inout Int) -> Card {
        var c = card
        let ordered = c.orderedFields
        for i in (0..<ordered.count).reversed() {
            guard excess > 0 else { break }
            let f = ordered[i]
            guard !f.fieldValue.isEmpty else { continue }

            let dropCount = min(excess, f.fieldValue.count)
            if let idx = c.fields.firstIndex(where: { $0.fieldName == f.fieldName && $0.fieldOrder == f.fieldOrder }) {
                c.fields[idx].fieldValue = String(f.fieldValue.dropLast(dropCount))
                excess -= dropCount
            }
        }
        return c
    }

    /// 从后往前移除标签，直到空间足够或标签为空
    private static func truncateTags(_ card: Card, excess: inout Int) -> Card {
        var c = card
        while excess > 0 && !c.tags.isEmpty {
            let tag = c.tags.removeLast()
            excess -= tag.count
        }
        return c
    }

    /// 截断标题末尾字符
    private static func truncateTitle(_ card: Card, excess: Int) -> Card {
        var c = card
        let dropCount = min(excess, c.title.count)
        c.title = String(c.title.dropLast(dropCount))
        return c
    }
}
