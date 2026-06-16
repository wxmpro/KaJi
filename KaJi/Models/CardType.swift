//
//  CardType.swift
//  KaJi
//
//  12 种内置卡片类型（按 V1 草稿第 4 条 + mockup v7.0.1 字段，v1.2.9 T7 注释修正 — 原本误写 11 种）。
//  source of truth：V1 草稿；mockup 字段命名差异以 V1 草稿为准。
//
//  每种类型定义：
//  - 显示名（中文）
//  - tint 色（侧栏 / 列表 / picker 都用这色）
//  - 字段集合（按显示顺序，含"标题"） + 唯一编码
//
//  字段在数据库里用 EAV 模式（cardFields 表）存储，UI 渲染时按 fields 顺序展示。
//

import SwiftUI

/// 12 种内置卡片类型 — 与 V1 草稿第 4 条 1:1 对应（v1.2.9 T7 注释修正 — 原本误写 11 种）
enum CardType: String, CaseIterable, Identifiable, Hashable {
    case term        = "术语卡"      // teal
    case counter     = "反常识卡"    // red
    case knowledge   = "新知卡"      // yellow
    case person      = "人物卡"      // blue
    case quote       = "金句卡"      // orange
    case newWord     = "新词卡"      // mint
    case action      = "行动卡"      // green
    case event       = "事件卡"      // indigo
    case graph       = "图示卡"      // mint-light
    case index       = "索引卡"      // gray
    case review      = "综述卡"      // purple
    case free        = "自由卡"      // gray-secondary

    var id: String { rawValue }

    /// tint 标识（与 mockup v7.0.1 的 data-tint 一致）
    enum Tint: String {
        case red, orange, blue, indigo, teal, gray, mint, yellow, green, purple
        case graySecondary = "gray-secondary"
        case mintLight     = "mint-light"
    }

    var tint: Tint {
        switch self {
        case .term:      return .teal
        case .counter:   return .red
        case .knowledge: return .yellow
        case .person:    return .blue
        case .quote:     return .orange
        case .newWord:   return .mint
        case .action:    return .green
        case .event:     return .indigo
        case .graph:     return .mintLight
        case .index:     return .gray
        case .review:    return .purple
        case .free:      return .graySecondary
        }
    }

    /// 该类型的所有"内容字段"（按显示顺序，不含"标题"和"唯一编码"）
    /// 注：标题每种类型都有；唯一编码每张卡都有；这两者不进 fields 数组
    var fields: [String] {
        switch self {
        case .term:      return ["定义", "解释", "例子", "参考"]
        case .counter:   return ["常识", "反常识", "例子", "参考"]
        case .knowledge: return ["已知", "新知", "例子", "参考"]
        case .person:    return ["简介", "参考"]
        case .quote:     return ["原句", "评论", "参考"]
        case .newWord:   return ["原句", "造句", "参考"]
        case .action:    return ["内容", "行动", "参考"]
        case .event:     return ["时间", "地点", "参与者", "经过", "理解", "参考"]
        case .graph:     return ["说明", "参考"]
        case .index:     return ["引用", "参考"]
        case .review:    return ["论点", "参考"]   // 6-14 用户：论述→论点，主题/要点删掉（标题即主题）
        case .free:      return ["内容", "参考"]   // 你新加的"内容"字段
        }
    }

    /// tint 对应颜色（macOS 调色板饱和度）
    var color: Color {
        switch tint {
        case .red:            return Color(red: 1.000, green: 0.271, blue: 0.227)   // #ff453a
        case .orange:         return Color(red: 1.000, green: 0.624, blue: 0.039)   // #ff9f0a
        case .blue:           return Color(red: 0.039, green: 0.518, blue: 1.000)   // #0a84ff
        case .indigo:         return Color(red: 0.369, green: 0.361, blue: 0.902)   // #5e5ce6
        case .teal:           return Color(red: 0.114, green: 0.561, blue: 0.749)   // #1d8fbf
        case .gray:           return Color(red: 0.388, green: 0.388, blue: 0.408)   // #636368
        case .mint:           return Color(red: 0.000, green: 0.706, blue: 0.675)   // #00b4ac
        case .mintLight:      return Color(red: 0.314, green: 0.792, blue: 0.682)   // #50c9ae 浅版以与 mint 区分
        case .yellow:         return Color(red: 0.659, green: 0.494, blue: 0.000)   // #a87e00
        case .green:          return Color(red: 0.157, green: 0.655, blue: 0.271)   // #28a745
        case .purple:         return Color(red: 0.686, green: 0.322, blue: 0.871)   // #af52de
        case .graySecondary:  return Color(red: 0.557, green: 0.557, blue: 0.576)   // #8e8e93
        }
    }
}
