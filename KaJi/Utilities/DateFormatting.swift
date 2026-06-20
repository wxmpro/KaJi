//
//  DateFormatting.swift
//  KaJi
//
//  统一日期格式化。用 Date.ISO8601FormatStyle（值类型，官方 Sendable，macOS 12+）
//  替代 ISO8601DateFormatter + nonisolated(unsafe)（线程安全依据不成立）。
//

import Foundation

enum DateFormatting {
    /// 带小数秒（与旧 ISO8601DateFormatter [.withInternetDateTime, .withFractionalSeconds] 等价）
    static let iso8601WithFraction: Date.ISO8601FormatStyle = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    /// 不带小数秒（fallback）
    static let iso8601: Date.ISO8601FormatStyle = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        includingFractionalSeconds: false,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    static func string(_ d: Date) -> String {
        d.formatted(iso8601WithFraction)
    }

    static func parse(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: iso8601WithFraction) { return d }
        return try? Date(s, strategy: iso8601)
    }
}
