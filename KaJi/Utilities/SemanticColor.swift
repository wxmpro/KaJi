//
//  SemanticColor.swift
//  KaJi
//
//  浅深模式双值色彩 token。
//  取代"按 Light/Dark 双写常量"模式，避免调用方写 `scheme == .dark ? xxx : yyy` 的三目。
//
//  设计原则：
//  - 单一值类型：每种语义色用 struct 表达，自动跟随 colorScheme 解析
//  - 调用方只写：`KaJiColor.cardBorder.resolve(for: colorScheme)` 一行
//  - 不持有 ColorScheme：resolve 时按需取，避免不必要的 environment 订阅
//

import SwiftUI

struct SemanticColor: Sendable {
    let light: Color
    let dark: Color

    func resolve(for scheme: ColorScheme) -> Color {
        scheme == .dark ? dark : light
    }
}