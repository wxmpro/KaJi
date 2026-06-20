//
//  KaJiMetrics.swift
//  KaJi
//
//  全局公共设计常量（命名空间式 enum，禁止实例化）。
//  消除横线穿字 bug 的根因（lineHeight 硬编码 24）。
//

import CoreGraphics

/// KaJi 全局设计常量（命名空间式 enum，禁止实例化）
///
/// 设计原则：
/// - 单一权威：所有依赖同一概念的值都引用这里，杜绝分散硬编码
/// - 数值依据：editorLineHeight = SwiftUI TextEditor (.systemFont 16 + lineSpacing 6) 实际行高
///   ≈ 25pt；NSTextView 强制 paragraphStyle 行高 = 25pt
enum KaJiMetrics {

    // MARK: - 编辑器

    /// 编辑器行高（pt）：唯一权威值
    ///
    /// 引用此常量的代码（必须保持同步）：
    /// - `NoScrollTextEditor` 内部 NSTextView 的 paragraphStyle 行高
    /// - `FormEditor.ruledPaper` 横线间隔 + firstY
    /// - `FormEditor.labelView` 字段名 fallback 高度
    /// - `FormEditor.typeButton` / `bottomMetaRow` 高度
    /// - `FormEditor.fieldEditor` 的 minHeight
    ///
    /// 改动此值的影响：横线、字段名、按钮、编辑器全部同步（不变视觉/交互关系）
    static let editorLineHeight: CGFloat = 25
}