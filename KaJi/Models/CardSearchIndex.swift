//
//  CardSearchIndex.swift
//  KaJi
//
//  搜索倒排索引。直接索引 CardSummary.searchText（title + tags + 字段值预拼接）。
//
//  分词策略：bigram + 子串校验（解决 CJK 单 token 问题）
//  - grams()：把可索引连续段切成 bigram（中文「卡片笔记」→ 卡片/片笔/笔记；
//    英文「hello」→ he/el/ll/lo），单字符段产 unigram。
//  - 倒排索引存 gram，搜索时用 query 的 grams 求候选交集（快速召回）。
//  - 再用 docLower 子串校验，消除 bigram 的假阳性（如搜「术卡」不会误中「术语卡」）。
//  - 单字 query（可索引字符 <2）走全集 + 子串校验，保证单字也能搜。
//
//  数据结构：
//  - 倒排：InvertedIndex = [gram: Set<CardID>]
//  - 正排：docText [id: searchText 原文]（变更检测）/
//          docLower [id: searchText 小写]（子串校验）/
//          docGrams [id: Set<gram>]（增量移除旧贡献）
//

import Foundation
import os

typealias InvertedIndex = [String: Set<String>]

/// 倒排索引。用 OSAllocatedUnfairLock 保护 4 个字典（取代"只在主线程调用"的注释约定）。
/// 保持 search(_:) 与 sync(to:) 同步签名不变，避免 async 沿调用链传染。
final class CardSearchIndex {
    private struct State {
        var index: InvertedIndex = [:]
        /// 正排：id → 上次索引时的 searchText 原文，用于「内容是否变化」的快速判定
        var docText: [String: String] = [:]
        /// 正排：id → searchText 小写，用于子串校验
        var docLower: [String: String] = [:]
        /// 正排：id → 该卡贡献的 gram 集合，用于增量移除旧贡献
        var docGrams: [String: Set<String>] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// 某字符是否可索引（字母或数字；中英文均可）
    private static func isIndexable(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// 把文本切成 gram 集合（输入需已小写）：
    /// - 按「可索引字符的连续段」分段（标点/空格作分隔）
    /// - 段长 1 → unigram（单字）；段长 ≥2 → 逐字 bigram
    /// 注：static 避免 withLock 闭包捕获 self（Swift 6 Sendable 检查）
    private static func grams(_ lower: String) -> Set<String> {
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

        state.withLock { s in
            // 1. 删除已不存在的卡
            for id in Array(s.docText.keys) where !newIDs.contains(id) {
                Self.removeDoc(id, state: &s)
            }

            // 2. 新增 / 更新变化的卡（未变化的卡直接跳过，省分词）
            for summary in summaries {
                if s.docText[summary.id] == summary.searchText { continue }
                Self.removeDoc(summary.id, state: &s)
                let lower = summary.searchText.lowercased()
                let g = Self.grams(lower)
                s.docText[summary.id] = summary.searchText
                s.docLower[summary.id] = lower
                s.docGrams[summary.id] = g
                for gram in g {
                    s.index[gram, default: []].insert(summary.id)
                }
            }
        }
    }

    /// 移除某卡的全部 gram 贡献与正排记录
    private static func removeDoc(_ id: String, state: inout State) {
        if let oldGrams = state.docGrams[id] {
            for gram in oldGrams {
                state.index[gram]?.remove(id)
                if state.index[gram]?.isEmpty == true {
                    state.index.removeValue(forKey: gram)
                }
            }
        }
        state.docGrams.removeValue(forKey: id)
        state.docText.removeValue(forKey: id)
        state.docLower.removeValue(forKey: id)
    }

    /// 多 term AND 搜索（空格分词，每个 term 都须命中）。
    /// 召回：term 的 grams 求候选交集；单字 term（可索引字符 <2）取全集。
    /// 精确：候选再经 docLower 子串校验，消除 bigram 假阳性。
    func search(_ keyword: String) -> Set<String> {
        let terms = keyword.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        return state.withLock { s -> Set<String> in
            var candidates: Set<String>? = nil
            for term in terms {
                let indexableCount = term.filter(Self.isIndexable).count
                let termCandidates: Set<String>
                if indexableCount < 2 {
                    // 单字/无可索引字符：取全集，靠子串校验收敛
                    termCandidates = Set(s.docLower.keys)
                } else {
                    let tg = Self.grams(term)
                    var inter: Set<String>? = nil
                    for gram in tg {
                        let set = s.index[gram] ?? []
                        inter = (inter == nil) ? set : inter!.intersection(set)
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
                guard let doc = s.docLower[id] else { continue }
                if terms.allSatisfy({ doc.contains($0) }) {
                    result.insert(id)
                }
            }
            return result
        }
    }

    /// 清空索引（含正排）
    func clear() {
        state.withLock { s in
            s.index.removeAll(keepingCapacity: false)
            s.docText.removeAll(keepingCapacity: false)
            s.docLower.removeAll(keepingCapacity: false)
            s.docGrams.removeAll(keepingCapacity: false)
        }
    }
}
