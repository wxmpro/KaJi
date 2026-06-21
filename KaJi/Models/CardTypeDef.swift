//
//  CardTypeDef.swift
//  KaJi
//
//  单个卡片类型的完整定义（内置与自定义统一结构）。
//  阶段1先从 CardType enum 生成内置定义；阶段2接入 DB 后同时承载自定义类型。
//

import SwiftUI

/// 一个卡片类型的完整定义。
/// 内置类型与自定义类型走同一套结构，UI/存储只认这套结构。
struct CardTypeDef: Identifiable, Hashable, Codable {
    /// 稳定唯一 key。
    /// - 内置类型：CardType.rawValue，如 "术语卡"
    /// - 自定义类型："custom:" + UUID
    /// - 兜底类型："builtin:fallback"
    let id: String

    /// 显示名（中文）
    var name: String

    /// 颜色序列化值。
    /// - 内置类型：CardType.Tint.rawValue
    /// - 自定义类型：HEX 或 SwiftUI Color 的 Codable 表示
    var colorRaw: String

    /// 中间内容字段（按显示顺序，不含"标题"和"参考"）
    var fieldNames: [String]

    /// true=内置（不可删），false=自定义
    var isBuiltin: Bool

    /// 全局显示顺序，数值越小越靠前
    var sortOrder: Int

    /// 解析后的显示颜色
    var color: Color {
        CardTypeDef.resolveColor(from: colorRaw)
    }

    /// 渲染用完整字段：标题 + 内容字段 + 参考
    /// 标题恒在首位，参考恒在末位
    var allFields: [String] {
        fieldNames + ["参考"]
    }
}

// MARK: - 颜色解析

extension CardTypeDef {
    /// 将 colorRaw 解析为 Color。
    /// 阶段1仅支持内置 tint 名；阶段2扩展为支持自定义 HEX。
    static func resolveColor(from rawValue: String) -> Color {
        // 优先按内置 Tint 解析
        if let tint = CardType.Tint(rawValue: rawValue) {
            return color(for: tint)
        }

        // 兜底：尝试解析 HEX（阶段2自定义类型使用）
        if let hexColor = Color(hex: rawValue) {
            return hexColor
        }

        // 最终兜底灰色
        return Color(red: 0.388, green: 0.388, blue: 0.408)
    }

    /// 内置 tint → Color 映射（复用原 CardType.color 逻辑）
    private static func color(for tint: CardType.Tint) -> Color {
        switch tint {
        case .red:            return Color(red: 1.000, green: 0.271, blue: 0.227)
        case .orange:         return Color(red: 1.000, green: 0.624, blue: 0.039)
        case .blue:           return Color(red: 0.039, green: 0.518, blue: 1.000)
        case .indigo:         return Color(red: 0.369, green: 0.361, blue: 0.902)
        case .teal:           return Color(red: 0.114, green: 0.561, blue: 0.749)
        case .gray:           return Color(red: 0.388, green: 0.388, blue: 0.408)
        case .mint:           return Color(red: 0.000, green: 0.706, blue: 0.675)
        case .mintLight:      return Color(red: 0.314, green: 0.792, blue: 0.682)
        case .yellow:         return Color(red: 0.659, green: 0.494, blue: 0.000)
        case .green:          return Color(red: 0.157, green: 0.655, blue: 0.271)
        case .purple:         return Color(red: 0.686, green: 0.322, blue: 0.871)
        case .graySecondary:  return Color(red: 0.557, green: 0.557, blue: 0.576)
        }
    }
}

// MARK: - HEX 颜色解析（阶段2自定义颜色前置）

private extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 || hexSanitized.count == 8 else {
            return nil
        }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r, g, b, a: Double
        if hexSanitized.count == 6 {
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
            a = Double(rgb & 0x000000FF) / 255.0
        }

        self.init(red: r, green: g, blue: b, opacity: a)
    }
}
