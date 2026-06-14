//
//  Tag.swift
//  KaJi
//
//  标签 — 与 Card 是 M:N 关系。
//  - name：标签字面（≤ 10 字符；trim 后空字符串 = 不合法）
//  - useCount：该标签被多少张卡引用（实时统计；不进表，从 cardTags JOIN 算）
//

import Foundation

struct Tag: Identifiable, Hashable, Codable {
    let id: Int              // SQLite 自增
    let name: String         // 标签字面
}
