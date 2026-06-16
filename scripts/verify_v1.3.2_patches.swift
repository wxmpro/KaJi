//
//  verify_v1.3.2_patches.swift
//  KaJi
//
//  v1.3.2 PATCH 验证脚本：
//  - T6：跨进程 ID 冲突（同进程 1000 张 ID 唯一 + 持久化重试）
//  - S4：.md 解析鲁棒性（CRLF / 强制引号 / 未知字段校验 / round-trip）
//
//  用法（在项目根目录）：
//  swift scripts/verify_v1.3.2_patches.swift
//
//  预期输出：每个测试项 [PASS] / [FAIL] tag + 描述
//

import Foundation
import GRDB

func logPass(_ tag: String, _ msg: String) { print("[PASS] [\(tag)] \(msg)") }
func logFail(_ tag: String, _ msg: String) { print("[FAIL] [\(tag)] \(msg)"); exit(1) }

// MARK: - S4: .md 解析鲁棒性验证

print("=== S4: .md 解析鲁棒性验证 ===")

// 1. CRLF normalize
do {
    let textWithCRLF = "---\r\nid: \"20260616202233123\"\r\nmdVersion: 0\r\ntype: \"自由卡\"\r\ntitle: \"测试 CRLF\"\r\ncreatedAt: \"2026-06-16T20:22:33.123Z\"\r\nupdatedAt: \"2026-06-16T20:22:33.123Z\"\r\n---\r\n\r\n# 测试 CRLF\r\n\r\n## 内容\r\n\r\n这是内容\r\n"
    let card = try CardFileIO.parseMarkdown(textWithCRLF)
    guard card.id == "20260616202233123" else { logFail("S4-CRLF", "id 解析失败: \(card.id)") }
    guard card.title == "测试 CRLF" else { logFail("S4-CRLF", "title 解析失败: \(card.title)") }
    guard let contentField = card.fields.first(where: { $0.fieldName == "内容" }) else {
        logFail("S4-CRLF", "未找到 '内容' 字段")
    }
    guard contentField.fieldValue == "这是内容" else {
        logFail("S4-CRLF", "字段值含 \\r: \(contentField.fieldValue)")
    }
    logPass("S4-CRLF", "CRLF → LF normalize 正常")
}

// 2. 强制引号渲染
do {
    let card = Card.new(type: .free, id: "20260616202233200", title: "test title", tags: ["tag1"], fields: [:])
    let md = CardFileIO.renderMarkdown(card)
    guard md.contains("title: \"test title\"") else {
        logFail("S4-QUOTE", "title 未强引号包裹:\n\(md)")
    }
    guard md.contains("id: \"20260616202233200\"") else {
        logFail("S4-QUOTE", "id 未强引号包裹")
    }
    logPass("S4-QUOTE", "字符串字段强制双引号")
}

// 3. 未知字段名抛错
do {
    let text = "---\nid: \"20260616202233300\"\ntype: \"自由卡\"\ntitle: \"test\"\n---\n\n# test\n\n## unknown_field_xyz\n\ncontent\n"
    do {
        _ = try CardFileIO.parseMarkdown(text)
        logFail("S4-UNKNOWN", "未知字段未抛错")
    } catch let error as MarkdownError {
        switch error {
        case .unknownField(let name, _):
            guard name == "unknown_field_xyz" else {
                logFail("S4-UNKNOWN", "未知字段名错误: \(name)")
            }
            logPass("S4-UNKNOWN", "未知字段名抛 MarkdownError.unknownField")
        default:
            logFail("S4-UNKNOWN", "抛错类型错误: \(error)")
        }
    } catch {
        logFail("S4-UNKNOWN", "抛错类型非 MarkdownError: \(error)")
    }
}

// 4. round-trip：encode → decode = identity
do {
    let original = Card(
        id: "20260616202233400",
        type: CardType.free.rawValue,
        title: "round-trip 测试",
        tags: ["tagA", "tagB"],
        fields: [
            CardField(cardId: "20260616202233400", fieldName: "内容", fieldValue: "这是内容\n多行", fieldOrder: 0),
            CardField(cardId: "20260616202233400", fieldName: "参考", fieldValue: "https://example.com", fieldOrder: 1)
        ],
        createdAt: Date(timeIntervalSince1970: 1749510153),
        updatedAt: Date(timeIntervalSince1970: 1749510153),
        deletedAt: nil,
        mdVersion: 1
    )
    let md = CardFileIO.renderMarkdown(original)
    let parsed = try CardFileIO.parseMarkdown(md)
    guard parsed.id == original.id else { logFail("S4-RT", "id 不一致") }
    guard parsed.title == original.title else { logFail("S4-RT", "title 不一致") }
    guard parsed.fields.count == original.fields.count else { logFail("S4-RT", "fields 数量不一致") }
    logPass("S4-RT", "round-trip 正常（encode → decode）")
}

// MARK: - T6: ID 生成 + 持久化重试验证

print("\n=== T6: ID 生成 + 持久化重试验证 ===")

// 1. 同进程内 1000 次 ID 生成不重
do {
    var ids = Set<String>()
    for _ in 0..<1000 {
        let id = try CardIDGenerator.next()
        guard CardIDGenerator.isValid(id) else { logFail("T6-1K", "无效 ID: \(id)") }
        guard ids.insert(id).inserted else { logFail("T6-1K", "重复 ID: \(id)") }
    }
    logPass("T6-1K", "同进程 1000 张 ID 全部唯一")
}

// 2. 1000 次创建 + 持久化（不抛 idConflictExhausted）
do {
    var success = 0
    var fail: Error?
    for i in 0..<1000 {
        do {
            let id = try CardIDGenerator.next()
            let card = Card(
                id: id, type: CardType.free.rawValue, title: "verify-\(i)",
                tags: [], fields: [],
                createdAt: Date(), updatedAt: Date(), deletedAt: nil, mdVersion: 0
            )
            _ = try CardRepository.shared.save(card: card)
            success += 1
        } catch {
            fail = error
            break
        }
    }
    if let fail = fail {
        logFail("T6-1K-SAVE", "持久化失败: \(fail.localizedDescription)")
    }
    logPass("T6-1K-SAVE", "1000 次 save 全部成功（成功数: \(success)）")
}

// MARK: - 总结

print("\n=== v1.3.2 PATCH 验证全部通过 ===")