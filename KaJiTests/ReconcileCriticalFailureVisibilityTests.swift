//
//  ReconcileCriticalFailureVisibilityTests.swift
//  KaJiTests
//
//  v1.6.1 测试地基：reconcileCritical 失败必须显式上报
//  对应 §4.1 修复回归：失败的 .md 恢复不能静默丢失
//

import XCTest
@testable import KaJi

final class ReconcileCriticalFailureVisibilityTests: XCTestCase {

    /// §4.1 修复回归：knownFieldNames 动态构建后，所有 CardType 字段名都在白名单内
    /// 间接验证：如果修复正确，reconcileCritical 不会因字段名不匹配而失败
    func test_allCardTypeFields_areInKnownFieldNames() {
        // 通过反射访问 CardFileIO.knownFieldNames 是 private 的
        // 改为验证一个等价不变量：每个 CardType.fields 中的字段都能被 CardFileIO 渲染且解析回来
        for type in CardType.allCases {
            for fieldName in type.fields {
                let id = "20260618120000001"
                let card = Card(
                    id: id,
                    type: type.rawValue,
                    title: "test",
                    tags: [],
                    fields: [CardField(cardId: id, fieldName: fieldName, fieldValue: "v", fieldOrder: 0)],
                    createdAt: Date(),
                    updatedAt: Date(),
                    deletedAt: nil,
                    mdVersion: 1
                )
                let md = CardFileIO.renderMarkdown(card)
                XCTAssertNoThrow(try CardFileIO.parseMarkdown(md),
                    "\(type.rawValue).\(fieldName) 必须在 knownFieldNames 白名单内")
            }
        }
    }
}
