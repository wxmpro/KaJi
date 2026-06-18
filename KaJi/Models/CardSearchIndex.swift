//
//  CardSearchIndex.swift
//  KaJi
//
//  v1.2.9 T5 引入：搜索倒排索引。
//  v1.3.0：直接索引 CardSummary.searchText（title + tags + 字段值预拼接）。
//  v1.5.0 增量化：rebuild → 增量 sync(to:)，未变化的卡跳过分词。
//  v1.5.0 中文分词修复（群2 P0）：旧 tokenize 用 CharacterSet.alphanumerics
//         切词，而 CJK 汉字属于 alphanumerics → 整段中文被当成「一个 token」，
//         搜「术语」无法命中「术语卡」→ 中文搜索 100% 失效。
//         改为 bigram（二元组）分词 + 子串校验：
//           - grams()：把可索引连续段切成 bigram（中文「卡片笔记」→ 卡片/片笔/
//             笔记；英文「hello」→ he/el/ll/lo），单字符段产 unigram。
//           - 倒排索引存 gram，搜索时用 query 的 grams 求候选交集（快速召回）。
//           - 再用 docLower 子串校验（query 必须是该卡小写全文的子串），消除
//             bigram 的假阳性（如搜「术卡」不会误中「术语卡」）。
//           - 单字 query（可索引字符 <2）走全集 + 子串校验，保证单字也能搜。
//
//  - 倒排结构：InvertedIndex = [gram: Set<CardID>]
//  - 正排结构：docText [id: searchText 原文]（变更检测）、
//             docLower [id: searchText 小写]（子串校验）、
//             docGrams [id: Set<gram>]（增量移除旧贡献）
//

import Foundation

typealias InvertedIndex = [String: Set<String>]

/// v1.2.9 T5 倒排索引（v1.5.0 增量化 + bigram 中文分词）。
/// - 线程安全约定：
///   - `search(_:)` 读操作：Set<String> 值类型不可变，跨线程并发读安全
///   - `sync(to:)` / `clear()` 写操作：仅在主线程调用
///     （StatsState.update → cardService.updateSearchIndex）
/// 因此可以不加 actor 隔离，从 Task.detached 后台也能安全 search。
final class CardSearchIndex {
    private(set) var index: InvertedIndex = [:]

    /// 正排：id → 上次索引时的 searchText 原文，用于「内容是否变化」的快速判定
    private var docText: [String: String] = [:]
    /// 正排：id → searchText 小写，用于子串校验
    private var docLower: [String: String] = [:]
    /// 正排：id → 该卡贡献的 gram 集合，用于增量移除旧贡献
    private var docGrams: [String: Set<String>] = [:]

    /// 某字符是否可索引（字母或数字；中英文均可）
    private static func isIndexable(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// 把文本切成 gram 集合（输入需已小写）：
    /// - 按「可索引字符的连续段」分段（标点/空格作分隔）
    /// - 段长 1 → unigram（单字）；段长 ≥2 → 逐字 bigram
    private func grams(_ lower: String) -> Set<String> {
        var result: Set<String> = []
        let chars = Array(lower)
        var i = 0
        while i < chars.count {
            guard Self.isIndexable(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count && Self.isIndexable(chars[j]) { j += 1 }
            let seg = chars[i..<j]
            if seg.count == 1 {
                result.insert(String(seg.first!))
            } else {
                let segArr = Array(seg)
                for k in 0..<(segArr.count - 1) {
                    result.insert(String(segArr[k...(k + 1)]))
                }
            }
            i = j
        }
        return result
    }

    /// 增量同步到给定的 [CardSummary]。
    /// - 删除：不在新集合里的卡，移除其全部 gram 贡献
    /// - 跳过：searchText 与上次相同的卡，完全不动（不分词）
    /// - 更新：searchText 变化的卡，先移除旧 gram 再加新 gram
    /// 首次 docText 为空 → 全部当作新增 → 等价全量构建。
    func sync(to summaries: [CardSummary]) {
        let newIDs = Set(summaries.map { $0.id })

        // 1. 删除已不存在的卡
        for id in Array(docText.keys) where !newIDs.contains(id) {
            removeDoc(id)
        }

        // 2. 新增 / 更新变化的卡（未变化的卡直接跳过，省分词）
        for s in summaries {
            if docText[s.id] == s.searchText { continue }
            removeDoc(s.id)
            let lower = s.searchText.lowercased()
            let g = grams(lower)
            docText[s.id] = s.searchText
            docLower[s.id] = lower
            docGrams[s.id] = g
            for gram in g {
                index[gram, default: []].insert(s.id)
            }
        }
    }

    /// 移除某卡的全部 gram 贡献与正排记录
    private func removeDoc(_ id: String) {
        if let oldGrams = docGrams[id] {
            for gram in oldGrams {
                index[gram]?.remove(id)
                if index[gram]?.isEmpty == true {
                    index.removeValue(forKey: gram)
                }
            }
        }
        docGrams.removeValue(forKey: id)
        docText.removeValue(forKey: id)
        docLower.removeValue(forKey: id)
    }

    /// 多 term AND 搜索（空格分词，每个 term 都须命中）。
    /// 召回：term 的 grams 求候选交集；单字 term（可索引字符 <2）取全集。
    /// 精确：候选再经 docLower 子串校验，消除 bigram 假阳性。
    func search(_ keyword: String) -> Set<String> {
        let terms = keyword.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        var candidates: Set<String>? = nil
        for term in terms {
            let indexableCount = term.filter(Self.isIndexable).count
            let termCandidates: Set<String>
            if indexableCount < 2 {
                // 单字/无可索引字符：取全集，靠子串校验收敛
                termCandidates = Set(docLower.keys)
            } else {
                let tg = grams(term)
                var inter: Set<String>? = nil
                for gram in tg {
                    let s = index[gram] ?? []
                    inter = (inter == nil) ? s : inter!.intersection(s)
                    if inter!.isEmpty { break }
                }
                termCandidates = inter ?? []
            }
            candidates = (candidates == nil) ? termCandidates : candidates!.intersection(termCandidates)
            if candidates!.isEmpty { return [] }
        }

        // 子串校验：每个 term 必须是该卡小写全文的子串
        var result: Set<String> = []
        for id in candidates ?? [] {
            guard let doc = docLower[id] else { continue }
            if terms.allSatisfy({ doc.contains($0) }) {
                result.insert(id)
            }
        }
        return result
    }

    /// 清空索引（含正排）
    func clear() {
        index.removeAll(keepingCapacity: false)
        docText.removeAll(keepingCapacity: false)
        docLower.removeAll(keepingCapacity: false)
        docGrams.removeAll(keepingCapacity: false)
    }
}
