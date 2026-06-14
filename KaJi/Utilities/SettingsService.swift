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

    /// 应用主题 — 同时写到 UserDefaults 并同步到 NSApp + 所有窗口
    static func applyTheme(_ mode: ThemeMode) {
        let key = "KaJi.theme"
        let appearance: NSAppearance?
        let value: String
        switch mode {
        case .follow:
            value = "follow"
            appearance = nil
        case .light:
            value = "light"
            appearance = NSAppearance(named: .aqua)
        case .dark:
            value = "dark"
            appearance = NSAppearance(named: .darkAqua)
        }
        UserDefaults.standard.set(value, forKey: key)

        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
            // 强制 titlebar 区域重绘
            window.contentView?.needsDisplay = true
        }
    }

    /// 启动时恢复主题偏好
    static func restoreThemeOnLaunch() {
        let value = UserDefaults.standard.string(forKey: "KaJi.theme") ?? "follow"
        let appearance: NSAppearance?
        switch value {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark":  appearance = NSAppearance(named: .darkAqua)
        default:       appearance = nil
        }
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}
