//
//  DraftState.swift
//  KaJi
//
//  草稿状态机：穷举所有可能状态，编译器强制处理每个 case。
//  case empty 携带 CardType，让空草稿可记住用户选择的类型。
//

import Foundation

/// 草稿状态机：穷举所有可能状态
enum DraftState: Equatable {
    /// 全新空白（无 UUID，未持久化），携带用户选择的类型
    case empty(CardType = .free)

    /// 编辑中（已持久化或持久化中）
    case editing(Card)

    /// 回收站只读
    case trash(Card)
}

extension DraftState {
    /// 派生：当前是否为回收站只读态
    var isTrashOnly: Bool {
        if case .trash = self { return true }
        return false
    }

    /// 派生：当前卡（任意状态都有值）
    var card: Card {
        switch self {
        case .empty(let type):
            return Card(
                id: Card.placeholderID,
                type: type.rawValue,
                title: "",
                tags: [],
                fields: type.fields.enumerated().map { idx, name in
                    CardField(cardId: Card.placeholderID, fieldName: name, fieldValue: "", fieldOrder: idx)
                },
                createdAt: .distantPast,
                updatedAt: .distantPast,
                deletedAt: nil
            )
        case .editing(let c), .trash(let c): return c
        }
    }

    /// 派生：当前卡 ID（.empty 时返回 nil）
    var cardID: String? {
        switch self {
        case .empty: return nil
        case .editing(let c), .trash(let c): return c.id
        }
    }

    /// 派生：当前卡类型
    var cardType: CardType {
        switch self {
        case .empty(let type): return type
        case .editing(let c), .trash(let c): return c.cardType
        }
    }

    /// 派生：当前标签
    var tags: [String] {
        switch self {
        case .empty: return []
        case .editing(let c), .trash(let c): return c.tags
        }
    }

    /// 派生：当前是否可软删除
    var canSoftDelete: Bool {
        if case .editing = self { return true }
        return false
    }

    /// 派生：当前是否可编辑
    var canEdit: Bool {
        if case .editing = self { return true }
        return false
    }

    /// 派生：当前是否只读
    var isReadOnly: Bool {
        if case .trash = self { return true }
        return false
    }

    /// 派生：当前是否有真实卡（非 placeholder）
    var hasRealCard: Bool {
        if case .empty = self { return false }
        return true
    }

    /// 派生：当前是否为空草稿
    var isEmptyDraft: Bool {
        if case .empty = self { return true }
        return false
    }

    // MARK: - 状态变更原语

    /// 设置空草稿的类型（仅 .empty 状态有效）
    mutating func setType(_ type: CardType) {
        if case .empty = self {
            self = .empty(type)
        }
    }
}