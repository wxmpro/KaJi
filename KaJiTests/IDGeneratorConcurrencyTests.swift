//
//  IDGeneratorConcurrencyTests.swift
//  KaJiTests
//
//  v1.6.1 测试地基：ID 生成器并发不变量
//  对应不变量 IV：进程内 ID 永不重复（同毫秒内 1 万并发 Task）
//

import XCTest
@testable import KaJi

final class IDGeneratorConcurrencyTests: XCTestCase {

    /// 不变量 IV：进程内 ID 单调高水位，并发生成 1 万个也不重复
    func test_concurrentGenerate_neverCollides() async throws {
        let count = 10_000
        let ids = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<count {
                group.addTask { try! CardIDGenerator.next() }
            }
            var result: [String] = []
            for await id in group { result.append(id) }
            return result
        }
        XCTAssertEqual(ids.count, count, "应生成 \(count) 个 ID")
        XCTAssertEqual(Set(ids).count, count, "进程内 ID 必须全部唯一（不变量 IV）")
    }

    /// 不变量 IV：连续生成的 ID 必须严格单调递增
    func test_sequentialGenerate_isMonotonic() throws {
        var prev = try CardIDGenerator.next()
        for _ in 0..<1000 {
            let curr = try CardIDGenerator.next()
            XCTAssertGreaterThan(curr, prev, "ID 必须单调递增：\(prev) → \(curr)")
            prev = curr
        }
    }

    /// 不变量 IV：格式必须是 17 位纯数字（向前兼容 .md 文件名）
    func test_format_is17Digits() throws {
        let id = try CardIDGenerator.next()
        XCTAssertEqual(id.count, 17)
        XCTAssertTrue(id.allSatisfy { $0.isNumber }, "ID 必须是纯数字：\(id)")
    }

    /// 不变量 IV：isValid 必须严格校验
    func test_isValid_strictFormat() {
        XCTAssertTrue(CardIDGenerator.isValid("20260618120000001"))
        XCTAssertFalse(CardIDGenerator.isValid("2026061812000000"))   // 16 位
        XCTAssertFalse(CardIDGenerator.isValid("202606181200000012"))  // 18 位
        XCTAssertFalse(CardIDGenerator.isValid("abcdefghijklmnopq"))   // 非数字
        XCTAssertFalse(CardIDGenerator.isValid(""))                    // 空
    }
}
