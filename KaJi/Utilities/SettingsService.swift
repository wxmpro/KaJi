//
//  SettingsService.swift
//  KaJi
//
//  设置的全局单例服务（主题 / 存储路径）。
//  v1.0 简化版 — 不持久化偏好，App 重启后回默认。
//

import AppKit

enum SettingsService {
    enum ThemeMode { case follow, light, dark }

    /// 应用主题 — 同时写到 UserDefaults
    static func applyTheme(_ mode: ThemeMode) {
        let key = "KaJi.theme"
        let value: String
        switch mode {
        case .follow: value = "follow"; NSApp.appearance = nil
        case .light:  value = "light";  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   value = "dark";   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// 启动时恢复主题偏好
    static func restoreThemeOnLaunch() {
        let value = UserDefaults.standard.string(forKey: "KaJi.theme") ?? "follow"
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
