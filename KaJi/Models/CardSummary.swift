//
//  CardSummary.swift
//  KaJi
//
//  轻量卡片缓存模型。替代 StatsState.cachedSummaries 中的完整 [Card]，节省内存。
//
//  字段：id / type / title / tags / searchText / updatedAt / deletedAt
//  - 列表渲染、软删除、搜索匹配所需字段全集
//  - 完整 fields 在打开编辑器时按需 CardRepository.card(id:) 懒加载
//

import Foundation

struct CardSummary: Identifiable, Hashable {
    let id: String
    let type: String           // CardType rawValue
    let title: String
    let tags: [String]
    /// title + tags + 字段值预拼接；CardSearchIndex 直接 tokenize
    let searchText: String
    let updatedAt: Date
    let deletedAt: Date?

    init(id: String, type: String, title: String, tags: [String], searchText: String, updatedAt: Date, deletedAt: Date?) {
        self.id = id
        self.type = type
        self.title = title
        self.tags = tags
        self.searchText = searchText
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    init(from card: Card) {
        self.id = card.id
        self.type = card.type
        self.title = card.title
        self.tags = card.tags
        self.searchText = ([card.title] + card.tags + card.fields.map(\.fieldValue))
            .joined(separator: " ")
        self.updatedAt = card.updatedAt
        self.deletedAt = card.deletedAt
    }

    /// CardType 便利访问
    var cardType: CardType { CardType(rawValue: type) ?? .free }

    /// 14 位显示 ID
    var displayID: String { String(id.prefix(14)) }
}
