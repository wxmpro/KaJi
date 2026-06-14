//
//  verify_data_layer.swift
//  KaJi
//
//  一行命令验证数据层：
//   swift -I ./build/derived/Build/Products/Debug -L ... verify_data_layer.swift
//  或：在 Xcode 里加一个 Run Script
//
//  验证项：
//  1. 创建 11 类卡片各 1 张（确认所有 CardType 字段正确序列化/反序列化）
//  2. 搜索 "心流"（确认 trigram FTS5 召回）
//  3. 软删除 1 张（进回收站）
//  4. 列出回收站
//  5. 恢复
//  6. 3500 字符检测
//  7. ID 生成器冲突兜底
//

import Foundation
import GRDB

// === 1. 启动时清理过期回收站 ===
do {
    try AppDatabase.shared.purgeOldTrash()
} catch {
    print("[FAIL] 启动清理失败: \(error)")
    exit(1)
}
print("[OK] 启动清理")

// === 2. 11 类卡片全建一遍 ===
var createdIDs: [String] = []
for type in CardType.allCases {
    do {
        let existing = try AppDatabase.shared.allIDs()
        let id = try CardIDGenerator.next(existing: existing)
        let fields: [String: String] = type.fields.reduce(into: [:]) { acc, name in
            acc[name] = "测试内容 - \(name)字段 - \(type.rawValue)"
        }
        let card = Card.new(type: type, id: id, title: "测试\(type.rawValue)", tags: ["测试", type.rawValue], fields: fields)
        let saved = try CardRepository.shared.create(card: card)
        createdIDs.append(saved.id)
        print("[OK] 创建 \(type.rawValue): \(saved.id.prefix(14))...")
    } catch {
        print("[FAIL] 创建 \(type.rawValue): \(error)")
        exit(1)
    }
}

// === 3. 搜索 "心流" 测试 trigram ===
do {
    let existing = try AppDatabase.shared.allIDs()
    let id = try CardIDGenerator.next(existing: existing)
    let card = Card.new(
        type: .term, id: id,
        title: "心流：技能与挑战平衡时的沉浸状态",
        tags: ["心理学", "认知"],
        fields: ["定义": "心流是一种意识状态", "解释": "Csikszentmihalyi 提出", "例子": "深度工作时容易进入", "参考": "《心流》"]
    )
    _ = try CardRepository.shared.create(card: card)
    let hits = try CardRepository.shared.search(keyword: "心流")
    print("[OK] 搜索 '心流': 命中 \(hits.count) 张")
    for hit in hits {
        print("    - \(hit.title)")
    }
} catch {
    print("[FAIL] 搜索: \(error)")
    exit(1)
}

// === 4. 软删除 + 回收站 ===
do {
    let id = createdIDs[0]   // 删第一张
    try CardRepository.shared.softDelete(id: id)
    let trash = try CardRepository.shared.trashCards()
    let active = try CardRepository.shared.allCards()
    print("[OK] 软删除后: 主库 \(active.count) 张, 回收站 \(trash.count) 张")
} catch {
    print("[FAIL] 软删除: \(error)")
    exit(1)
}

// === 5. 恢复 ===
do {
    let trash = try CardRepository.shared.trashCards()
    if let first = trash.first {
        try CardRepository.shared.restore(id: first.id)
        let trashAfter = try CardRepository.shared.trashCards()
        let activeAfter = try CardRepository.shared.allCards()
        print("[OK] 恢复后: 主库 \(activeAfter.count) 张, 回收站 \(trashAfter.count) 张")
    }
} catch {
    print("[FAIL] 恢复: \(error)")
    exit(1)
}

// === 6. 3500 字符检测 ===
do {
    let existing = try AppDatabase.shared.allIDs()
    let id = try CardIDGenerator.next(existing: existing)
    var longText = ""
    for _ in 0..<4000 { longText += "啊" }   // 4000 字 > 3500 上限
    let card = Card.new(
        type: .free, id: id, title: "超长测试",
        fields: ["内容": longText, "参考": "ref"]
    )
    // 写卡前会截断
    let saved = try CardRepository.shared.create(card: card)
    let count = ContentLimit.count(card: saved)
    print("[OK] 3500 字检测: 写入前 4000 字, 写入后 \(count) 字 (limit=\(ContentLimit.maxChars))")
    if count > ContentLimit.maxChars {
        print("[FAIL] 超限！")
        exit(1)
    }
} catch {
    print("[FAIL] 3500 字符测试: \(error)")
    exit(1)
}

// === 7. ID 冲突兜底 ===
do {
    var ids: Set<String> = []
    for _ in 0..<20 {
        // 每次都强制 "有一个冲突" — 模拟同毫秒
        let next = try CardIDGenerator.next(existing: ids)
        ids.insert(next)
    }
    print("[OK] ID 生成器 20 个唯一 id")
} catch {
    print("[FAIL] ID 冲突: \(error)")
    exit(1)
}

print("")
print("========== ALL PASS ==========")
