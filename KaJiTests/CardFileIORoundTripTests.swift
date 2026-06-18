//
//  CardFileIORoundTripTests.swift
//  KaJiTests
//
//  v1.6.1 测试地基：12 种卡型往返恒等
//  对应不变量 III：parse(render(card)) == card
//

import XCTest
@testable import KaJi

final class CardFileIORoundTripTests: XCTestCase {

    /// 不变量 III：12 种卡型全部往返恒等
    /// 这是修 BUG-3（render 写中文 / parse 认英文 100% 不匹配）的核心回归测试
    func test_roundTrip_allCardTypes() throws {
        for type in CardType.allCases {
            let original = makeCard(type: type, id: makeStableID(for: type))
            let md = CardFileIO.renderMarkdown(original)
            let parsed = try CardFileIO.parseMarkdown(md)

            XCTAssertEqual(parsed.type, original.type, "\(type.rawValue) type mismatch")
            XCTAssertEqual(parsed.title, original.title, "\(type.rawValue) title mismatch")
            XCTAssertEqual(parsed.tags.sorted(), original.tags.sorted(), "\(type.rawValue) tags mismatch")
            XCTAssertEqual(parsed.fields.count, original.fields.count, "\(type.rawValue) field count mismatch")
        }
    }

    /// 不变量 III：空标签列表也能往返
    func test_roundTrip_noTags() throws {
        let original = Card(
            id: "20260618120000001",
            type: CardType.free.rawValue,
            title: "无标签测试",
            tags: [],
            fields: [CardField(cardId: "20260618120000001", fieldName: "内容", fieldValue: "测试", fieldOrder: 0)],
            createdAt: Date(timeIntervalSince1970: 1740000000),
            updatedAt: Date(timeIntervalSince1970: 1740000001),
            deletedAt: nil,
            mdVersion: 5
        )
        let md = CardFileIO.renderMarkdown(original)
        let parsed = try CardFileIO.parseMarkdown(md)
        XCTAssertEqual(parsed.tags, [])
    }

    /// 不变量 III：deletedAt 不为 nil 的卡也能往返（修复 §4.1 隐含）
    func test_roundTrip_withDeletedAt() throws {
        let deleted = Date(timeIntervalSince1970: 1740000010)
        let original = Card(
            id: "20260618120000002",
            type: CardType.free.rawValue,
            title: "已删除",
            tags: ["测试"],
            fields: [],
            createdAt: Date(timeIntervalSince1970: 1740000000),
            updatedAt: Date(timeIntervalSince1970: 1740000005),
            deletedAt: deleted,
            mdVersion: 3
        )
        let md = CardFileIO.renderMarkdown(original)
        let parsed = try CardFileIO.parseMarkdown(md)
        XCTAssertNotNil(parsed.deletedAt)
        XCTAssertEqual(parsed.deletedAt!.timeIntervalSince1970, deleted.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 不变量 III：含特殊字符的内容（引号、反斜杠、换行）正确转义
    func test_roundTrip_specialCharacters() throws {
        let original = Card(
            id: "20260618120000003",
            type: CardType.free.rawValue,
            title: "标题含 \"引号\" 与 \\反斜杠\\",
            tags: ["tag\"with\"quote"],
            fields: [
                CardField(cardId: "20260618120000003", fieldName: "内容", fieldValue: "第一行\n第二行\t制表符", fieldOrder: 0)
            ],
            createdAt: Date(timeIntervalSince1970: 1740000000),
            updatedAt: Date(timeIntervalSince1970: 1740000001),
            deletedAt: nil,
            mdVersion: 1
        )
        let md = CardFileIO.renderMarkdown(original)
        let parsed = try CardFileIO.parseMarkdown(md)
        XCTAssertEqual(parsed.title, original.title)
        XCTAssertEqual(parsed.tags, original.tags)
        XCTAssertEqual(parsed.fields.first?.fieldValue, original.fields.first?.fieldValue)
    }

    // MARK: - 辅助

    private func makeCard(type: CardType, id: String) -> Card {
        var fields: [CardField] = type.fields.enumerated().map { idx, name in
            CardField(cardId: id, fieldName: name, fieldValue: "[\(name)的值]", fieldOrder: idx)
        }
        // 保留 title 作为不可空字段
        let title = fields.first?.fieldValue ?? ""
        fields.removeFirst()
        return Card(
            id: id,
            type: type.rawValue,
            title: title,
            tags: ["tag1", "tag2"],
            fields: fields,
            createdAt: Date(timeIntervalSince1970: 1740000000),
            updatedAt: Date(timeIntervalSince1970: 1740000001),
            deletedAt: nil,
            mdVersion: 1
        )
    }

    private func makeStableID(for type: CardType) -> String {
        // 用类型名 hash 生成 17 位稳定 ID（避免随机 ID 导致 diff 失败）
        let hash = abs(type.rawValue.hashValue)
        let suffix = String(format: "%017d", hash % 100_000_000_000_000_000)
        return suffix
    }
}
