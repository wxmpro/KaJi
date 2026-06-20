//
//  CardIDGenerator.swift
//  KaJi
//
//  17 位纯数字 ID 生成器。
//
//  格式：YYYYMMDDHHMMSS(14) + 纳秒末 3 位(0..999)
//  - 文件名 / URL / 内部存储：17 位
//  - UI 显示（displayID）：14 位（前缀 prefix(14)），见 Card.displayID
//
//  纳秒来源：DispatchTime.now().uptimeNanoseconds（monotonic clock，纳秒精度）
//  跨进程同时建卡的纳秒碰撞：靠 DB UNIQUE 约束 + CardRepository.persist 重试兜底
//
//  为什么不直接用 UUIDv7 / 真纳秒：
//  - KaJi 文件名依赖 17 位纯数字 ID（向后兼容已有 .md 文件名）
//  - UUIDv7 是 36 位字符串，破坏文件名 + 用户视觉习惯
//  - 17 位 + 纳秒末 3 位在人手建卡频率下几乎不撞，DB 兜底处理极端
//

import Foundation
import os

struct CardIDGenerator: Sendable {

    enum IDError: Error, LocalizedError {
        case systemClockMalfunction

        var errorDescription: String? {
            switch self {
            case .systemClockMalfunction:
                return "系统时钟异常：无法生成新的卡片编码"
            }
        }
    }

    /// 生成下一个 17 位 ID。
    /// - 格式：YYYYMMDDHHMMSS(14) + 纳秒末 3 位(0..999)
    /// - 跨进程同时建卡：DB UNIQUE 约束 + CardRepository.persist 重试
    static func next() throws -> String {
        // 1. wall clock — Calendar 提取 YYYYMMDDHHMMSS（系统时区，UI 友好）
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let h = comps.hour, let mi = comps.minute, let s = comps.second else {
            throw IDError.systemClockMalfunction
        }

        // 2. 纳秒末 3 位 — monotonic clock 纳秒（macOS 实际精度微秒级，足够分散）
        //    不再用进程内单调计数器：人手建卡间隔 ≥ 200ms，纳秒末 3 位天然不同
        //    极端碰撞（同进程同纳秒 / 跨进程同时建卡）靠 DB UNIQUE + 重试
        let nanoTail = Int(DispatchTime.now().uptimeNanoseconds % 1000)

        // 3. 拼 17 位
        let prefix = String(format: "%04d%02d%02d%02d%02d%02d", y, m, d, h, mi, s)
        let suffix = String(format: "%03d", nanoTail)
        return prefix + suffix
    }

    /// 校验给定字符串是否合法 17 位纯数字
    static func isValid(_ id: String) -> Bool {
        id.count == 17 && id.allSatisfy { $0.isNumber }
    }
}
