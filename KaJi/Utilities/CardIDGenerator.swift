//
//  CardIDGenerator.swift
//  KaJi
//
//  17 位唯一编码生成器 — YYYYMMDDHHMMSS (14 位) + 3 位毫秒。
//
//  冲突兜底（你说"不可能毫秒内写两张卡，但代码要有防御性 +1ms"）：
//  - 生成时取 Date.now 的毫秒
//  - 若与已有的 id 冲突，则 ms + 1 重试
//  - 最多重试 1000 次（理论上限 = 1000 张/毫秒 — 物理不可能）
//  - 1000 次都冲突说明系统时钟严重回退 → 抛错（让上层 UI 提示）
//
//  用途：未来 UI 调 `try generator.next(existing: ...)` 即可。
//

import Foundation

struct CardIDGenerator {

    enum IDError: Error, LocalizedError {
        case systemClockMalfunction
        case tooManyCollisions

        var errorDescription: String? {
            switch self {
            case .systemClockMalfunction:
                return "系统时钟异常：无法生成新的卡片编码"
            case .tooManyCollisions:
                return "同一毫秒内已生成超过 1000 张卡片，物理不可能"
            }
        }
    }

    /// 17 位纯数字：YYYYMMDDHHMMSS + 3 位毫秒
    /// - Parameter existing: 已存在的 id 集合（用于冲突检测）
    /// - Returns: 新生成的 17 位字符串
    static func next(existing: Set<String> = []) throws -> String {
        var now = Date()
        let cal = Calendar(identifier: .gregorian)
        // 用 DateComponents 提时间位（防 Date 跨时区错乱）
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)

        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let h = comps.hour, let mi = comps.minute, let s = comps.second,
              let ns = comps.nanosecond else {
            throw IDError.systemClockMalfunction
        }
        let ms = ns / 1_000_000   // 纳秒 → 毫秒（0..999）

        let prefix = String(format: "%04d%02d%02d%02d%02d%02d", y, m, d, h, mi, s)
        let candidate = String(format: "%@%03d", prefix, ms)

        if !existing.contains(candidate) { return candidate }

        // 冲突兜底 — 1ms 内 +1 重复生成
        var attempt = 0
        var bumpedMs = ms
        var bumpedSec = s
        var bumpedComps = comps
        while attempt < 1000 {
            attempt += 1
            bumpedMs += 1
            if bumpedMs >= 1000 {
                bumpedMs = 0
                bumpedSec += 1
                if bumpedSec >= 60 {
                    // 进位到下一分钟
                    bumpedSec = 0
                    // 重取 now + 1s
                    now = now.addingTimeInterval(60)
                    let newComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
                    guard let y2 = newComps.year, let m2 = newComps.month, let d2 = newComps.day,
                          let h2 = newComps.hour, let mi2 = newComps.minute, let s2 = newComps.second,
                          let ns2 = newComps.nanosecond else {
                        throw IDError.systemClockMalfunction
                    }
                    bumpedComps = newComps
                    let newPrefix = String(format: "%04d%02d%02d%02d%02d%02d", y2, m2, d2, h2, mi2, s2)
                    let newMs = ns2 / 1_000_000
                    let cand = String(format: "%@%03d", newPrefix, newMs)
                    if !existing.contains(cand) { return cand }
                    continue
                }
            }
            let prefix2 = String(format: "%04d%02d%02d%02d%02d%02d", bumpedComps.year!, bumpedComps.month!, bumpedComps.day!, bumpedComps.hour!, bumpedComps.minute!, bumpedSec)
            let cand = String(format: "%@%03d", prefix2, bumpedMs)
            if !existing.contains(cand) { return cand }
        }
        throw IDError.tooManyCollisions
    }

    /// 校验给定字符串是否合法 17 位纯数字
    static func isValid(_ id: String) -> Bool {
        id.count == 17 && id.allSatisfy { $0.isNumber }
    }

    /// 14 位显示用（前缀）
    static func displayID(of id: String) -> String { String(id.prefix(14)) }
}
