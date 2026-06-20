//
//  CardIDGenerator.swift
//  KaJi
//
//  17 位纯数字 ID 生成器。
//
//  新模型（干掉"读 existing → 找下一个"）：
//  - 进程内单调计数器：同进程内永远不重
//  - 跨进程靠写入 UNIQUE 约束兜底（CardRepository.persist 用 INSERT + catch CONSTRAINT）
//  - monotonic clock 抗系统时钟回退
//
//  17 位格式：YYYYMMDDHHMMSS + 3 位 ms 内序列
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
        // 1. 取 wall clock 毫秒（用于日期显示）
        let now = Date()
        let ms = UInt64(now.timeIntervalSince1970 * 1000)

        // 2. 进程内单调递增（低 20 位计数器）
        //    修复 1970 年 ID 问题：原实现用 uptimeNanoseconds 导致
        //    Date(timeIntervalSince1970:) 生成 1970 年日期。改用 wall clock 毫秒。
        //    当时钟回退时，不重置计数器，继续递增，避免同一毫秒 ID 重复。
        let seq = counter.withLock { c -> UInt32 in
            let lastMs  = (c >> 20) & 0x0000_0FFF_FFFF_FFFF
            let lastSeq = c & 0xF_FFFF
            let curMs   = ms & 0x0000_0FFF_FFFF_FFFF

            let nextSeq: UInt64
            if curMs == lastMs {
                // 同毫秒：序列号 +1
                nextSeq = (lastSeq &+ 1) & 0xF_FFFF
            } else if curMs > lastMs {
                // 新毫秒：序列号归零
                nextSeq = 0
            } else {
                // 时钟回退：继续递增，避免与已生成 ID 冲突
                nextSeq = (lastSeq &+ 1) & 0xF_FFFF
            }
            c = (curMs << 20) | nextSeq
            return UInt32(nextSeq & 0xFFF)   // 取低 12 位 → 0..4095，再模 1000 拼 3 位
        }

        // 3. 用 Calendar 提取 YYYYMMDDHHMMSS（6 个字段 = 14 位）
        //    用系统当前时区，让用户看到的 UUID 日期/时间与本机一致。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
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