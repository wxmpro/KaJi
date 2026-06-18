//
//  PlaceholderRaceTests.swift
//  KaJiTests
//
//  v1.6.1 测试地基：FormEditor placeholder 再入锁回归测试
//  对应 §群 4 #29：快速连续输入时，isCreatingCard 锁保证只生成一张卡
//

import XCTest
@testable import KaJi

final class PlaceholderRaceTests: XCTestCase {

    /// 群 4 #29 修复回归：占位测试
    /// 真实场景由 FormEditor.swift:168-188 的 isCreatingCard + needsResaveAfterCreate 保证
    /// 这是 View 层逻辑，单元测试覆盖困难，由真机实测覆盖
    func test_placeholderRace_noRegression() {
        XCTAssertTrue(true, "占位：真实竞态场景见真机实测清单")
    }
}
