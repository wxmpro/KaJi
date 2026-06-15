//
//  ListFilter.swift
//  KaJi
//
//  右栏列表的筛选来源。
//  从 EditorState / ListState / StatsState 等状态对象中独立出来，避免 UI 状态容器与筛选逻辑耦合。
//

import Foundation

/// 卡片列表的筛选条件
enum ListFilter: Equatable {
    case type(CardType)
    case tag(String)
    case trash
    case all
    case search(String)
}

extension ListFilter {
    /// 筛选条件对应的展示标题（用于顶部条）
    var title: String {
        switch self {
        case .type(let t):   return t.rawValue
        case .tag(let s):    return "#\(s)"
        case .trash:         return "回收站"
        case .all:           return "全部卡片"
        case .search(let s): return "搜索：\(s)"
        }
    }
}
