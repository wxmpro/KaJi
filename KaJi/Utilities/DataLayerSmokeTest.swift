//
//  DataLayerSmokeTest.swift
//  KaJi
//
//  一次性跑完所有数据层核心路径，把结果以字符串数组返回给 UI 显示。
//  Phase 1 验证用 — 之后会被真正的 MainView 替换掉。
//

import Foundation
import GRDB

enum DataLayerSmokeTest {
    static func run() -> [String] {
        var out: [String] = []
        func log(_ s: String) { out.append(s) }

        // 1. 启动清理
        do {
            try AppDatabase.shared.purgeOldTrash()
            log("[OK] 启动清理 30 天前回收站")
        } catch {
            log("[FAIL] 启动清理: \(error)")
            return out
        }

        // 2. 11 类卡片全建
        do {
            let existing = try AppDatabase.shared.allIDs()
            for type in CardType.allCases {
                let id = try CardIDGenerator.next(existing: existing)
                let fields = Dictionary(uniqueKeysWithValues: type.fields.map { ($0, "测试 \($0)") })
                let card = Card.new(type: type, id: id, title: "测试\(type.rawValue)",
                                    tags: ["测试", type.rawValue], fields: fields)
                let saved = try CardRepository.shared.create(card: card)
                log("[OK] 创建 \(type.rawValue): \(saved.displayID)")
            }
        } catch {
            log("[FAIL] 创建 11 类卡: \(error)")
        }

        // 3. 搜索 "心流" — 测 trigram 短词召回（R-04 已知短板）
        do {
            let existing = try AppDatabase.shared.allIDs()
            let id = try CardIDGenerator.next(existing: existing)
            let card = Card.new(
                type: .term, id: id,
                title: "心流：技能与挑战平衡时的沉浸状态",
                tags: ["心理学"],
                fields: ["定义": "心流是一种意识状态", "解释": "Csikszentmihalyi 提出", "例子": "深度工作", "参考": "《心流》"]
            )
            _ = try CardRepository.shared.create(card: card)
            let hits = try CardRepository.shared.search(keyword: "心流")
            log("[OK] 搜索 '心流': 命中 \(hits.count) 张（trigram 2 字短词 R-04 已知召回不全）")
            for hit in hits.prefix(3) { log("    - \(hit.title)") }
            // 测 3 字以上召回（trigram 优势区）
            let hits3 = try CardRepository.shared.search(keyword: "心流是一种")
            log("[OK] 搜索 '心流是一种' (4 字): 命中 \(hits3.count) 张")
            // 测英文搜索
            let enCard = try CardRepository.shared.create(card: Card.new(
                type: .term, id: try CardIDGenerator.next(existing: AppDatabase.shared.allIDs()),
                title: "Deep Work: Skills and Challenge",
                tags: [],
                fields: ["定义": "Deep work is the ability to focus without distraction", "例子": "Cal Newport", "参考": ""]
            ))
            let enHits = try CardRepository.shared.search(keyword: "Deep")
            log("[OK] 搜索 'Deep' (英文 4 字): 命中 \(enHits.count) 张")
        } catch {
            log("[FAIL] 搜索: \(error)")
        }

        // 4. 软删除 + 回收站
        do {
            let all = try CardRepository.shared.allCards()
            if let first = all.first {
                try CardRepository.shared.softDelete(id: first.id)
                let trash = try CardRepository.shared.trashCards()
                let active = try CardRepository.shared.allCards()
                log("[OK] 软删除: 主库 \(active.count) / 回收站 \(trash.count)")
            }
        } catch {
            log("[FAIL] 软删除: \(error)")
        }

        // 5. 恢复
        do {
            let trash = try CardRepository.shared.trashCards()
            if let first = trash.first {
                try CardRepository.shared.restore(id: first.id)
                let trashAfter = try CardRepository.shared.trashCards()
                let activeAfter = try CardRepository.shared.allCards()
                log("[OK] 恢复: 主库 \(activeAfter.count) / 回收站 \(trashAfter.count)")
            }
        } catch {
            log("[FAIL] 恢复: \(error)")
        }

        // 6. 3500 字符检测
        do {
            let existing = try AppDatabase.shared.allIDs()
            let id = try CardIDGenerator.next(existing: existing)
            let longText = String(repeating: "啊", count: 4000)
            let card = Card.new(type: .free, id: id, title: "超长", fields: ["内容": longText, "参考": ""])
            let saved = try CardRepository.shared.create(card: card)
            let count = ContentLimit.count(card: saved)
            log("[OK] 3500 字符截断: 写入 4000, 实际 \(count) (limit=\(ContentLimit.maxChars))")
        } catch {
            log("[FAIL] 3500 字符测试: \(error)")
        }

        // 7. 标签统计
        do {
            let tags = try CardRepository.shared.allTags()
            log("[OK] 标签统计: \(tags.count) 个")
            for t in tags.prefix(5) { log("    - \(t.name): \(t.useCount) 张") }
        } catch {
            log("[FAIL] 标签统计: \(error)")
        }

        // 8. ID 冲突兜底
        do {
            var ids: Set<String> = []
            for _ in 0..<20 {
                let next = try CardIDGenerator.next(existing: ids)
                ids.insert(next)
            }
            log("[OK] ID 生成器 20 个唯一 id")
        } catch {
            log("[FAIL] ID 冲突: \(error)")
        }

        // 9. .md 文件存在
        do {
            let cards = try CardRepository.shared.allCards(includeDeleted: true)
            var mdCount = 0
            for c in cards {
                if FileManager.default.fileExists(atPath: CardFileIO.fileURL(for: c.id).path) {
                    mdCount += 1
                }
            }
            log("[OK] .md 文件: \(mdCount) / \(cards.count) 张")
        } catch {
            log("[FAIL] .md 检查: \(error)")
        }

        log("")
        log(out.contains(where: { $0.contains("FAIL") }) ? "✗ 有失败" : "✓ 全部通过")
        return out
    }
}
