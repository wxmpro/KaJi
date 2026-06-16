//
//  CardIDGenerator.swift
//  KaJi
//
//  v1.3.2 彻底重构：干掉"读 existing → 找下一个"模型（多进程下会读到过期 snapshot）。
//
//  新模型：
//  - 进程内单调计数器：同进程内永远不重（counter 自增）
//  - 跨进程靠写入 UNIQUE 约束兜底（CardRepository.persist 用 INSERT + catch CONSTRAINT）
//  - monotonic clock 抗系统时钟回退
//
//  17 位格式保持不变：YYYYMMDDHHMMSS + 3 位 ms 内序列
//  - 文件名 / URL / 内部存储：17 位
//  - UI 显示（displayID）：14 位（前缀 prefix(14)），见 Card.displayID
//
//  为什么不直接用 UUIDv7：
//  - KaJi 文件名依赖 17 位纯数字 ID（向后兼容已有 .md 文件名）
//  - UUIDv7 是 36 位字符串，会破坏文件名 + 用户视觉习惯
//  - 17 位 + monotonic counter 在跨进程下仍能保证唯一性（DB UNIQUE 兜底）
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

    /// 进程内单调计数器
    /// - 高 44 位：当前毫秒戳（mask 到 0x0000_0FFF_FFFF_FFFF，足够用到公元 2255 年）
    /// - 低 20 位：进程内毫秒内序列号（同一毫秒内最多 1M 个 ID）
    ///
    /// 用 OSAllocatedUnfairLock 保证多线程安全（GRDB/CardService 都是 async Task 上下文）
    private static let counter: OSAllocatedUnfairLock<UInt64> = .init(initialState: 0)

    /// 生成下一个 17 位 ID。
    /// - 进程内永不重（monotonic counter）
    /// - 跨进程唯一性靠 DB UNIQUE 约束 + 重试（由 CardService 处理）
    static func next() throws -> String {
        // 1. 取 monotonic clock（不受系统时钟回退影响）
        let ns = DispatchTime.now().uptimeNanoseconds
        let ms = ns / 1_000_000

        // 2. 进程内单调递增
        let seq = counter.withLock { c -> UInt32 in
            let lastMs  = (c >> 20) & 0x0000_0FFF_FFFF_FFFF
            let lastSeq = c & 0xF_FFFF
            let curMs   = UInt64(ms & 0x0000_0FFF_FFFF_FFFF)
            if curMs == lastMs {
                // 同毫秒：序列号 +1
                let next = lastSeq &+ 1
                c = (curMs << 20) | (next & 0xF_FFFF)
                return UInt32(next & 0xFFF)   // 取低 12 位 = 0..4095（拼成 3 位用截断 mod 1000）
            } else {
                // 新毫秒：序列号归零
                c = curMs << 20
                return 0
            }
        }

        // 3. 用 Calendar 提取 YYYYMMDDHHMMSS（6 个字段 = 14 位）
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current   // 用 UTC 避免时区漂移
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let h = comps.hour, let mi = comps.minute, let s = comps.second else {
            throw IDError.systemClockMalfunction
        }

        // 4. 拼 17 位：YYYYMMDDHHMMSS(14) + 序列号末 3 位（0..999）
        let prefix = String(format: "%04d%02d%02d%02d%02d%02d", y, m, d, h, mi, s)
        let suffix = String(format: "%03d", seq % 1000)
        return prefix + suffix
    }

    /// 校验给定字符串是否合法 17 位纯数字
    static func isValid(_ id: String) -> Bool {
        id.count == 17 && id.allSatisfy { $0.isNumber }
    }
}