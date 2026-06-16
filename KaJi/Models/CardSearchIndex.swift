//
//  CardSearchIndex.swift
//  KaJi
//
//  v1.2.9 T5 引入：搜索倒排索引。
//  v1.3.0：直接索引 CardSummary.searchText（title + tags + 字段值预拼接），
//         一次 tokenize 覆盖全部可搜索文本，搜索可命中字段值。
//
//  - 索引结构：InvertedIndex = [lowercased term: Set<CardID>]
//  - 构建时机：每次 refreshStats 后全量重建（在 StatsState.update 中触发）
//  - 内存占用：10k 卡约 5MB
//  - 搜索算法：多 term 求交集（AND）
//  - tokenize 阈值：term 长度 ≥ 2 才索引
//

import Foundation

typealias InvertedIndex = [String: Set<String>]

/// v1.2.9 T5 倒排索引。
/// - 线程安全约定：
///   - `search(_:)` 读操作：Set<String> 是值类型不可变，跨线程并发读安全
///   - `rebuild(from:)` 写操作：仅在主线程调用（StatsState.update → cardService.updateSearchIndex）
///   - `clear()` 写操作：仅在主线程调用
/// 因此可以不加 actor 隔离，从 Task.detached 后台也能安全 search。
final class CardSearchIndex {
    private(set) var index: InvertedIndex = [:]

    /// tokenize：按非字母数字分割，小写化，过滤 < 2 字符
    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// 从 [CardSummary] 全量重建
    /// v1.3.0：searchText 已预拼接 title + tags + 字段值，
    ///        一次 tokenize 覆盖全部可搜索文本
    func rebuild(from summaries: [CardSummary]) {
        index.removeAll(keepingCapacity: true)
        for s in summaries {
            for term in tokenize(s.searchText) {
                index[term, default: []].insert(s.id)
            }
        }
    }

    /// 多 term AND 搜索
    func search(_ keyword: String) -> Set<String> {
        let terms = tokenize(keyword)
        guard let first = terms.first else { return [] }
        var result = index[first] ?? []
        for term in terms.dropFirst() {
            result.formIntersection(index[term] ?? [])
        }
        return result
    }

    /// 清空索引
    func clear() {
        index.removeAll(keepingCapacity: false)
    }
}
