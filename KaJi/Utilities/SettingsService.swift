//
//  SettingsService.swift
//  KaJi
//
//  设置的全局单例服务。
//  负责主题、启动行为、自动保存间隔、回收站保留天数等通用设置的读写。
//

import AppKit
import Foundation

@MainActor
enum SettingsService {
    // MARK: - 键名
    private static let themeKey = "KaJi.theme"
    private static let launchBehaviorKey = "KaJi.launchBehavior"
    private static let autoSaveIntervalKey = "KaJi.autoSaveInterval"
    private static let trashRetentionDaysKey = "KaJi.trashRetentionDays"

    // MARK: - 枚举类型

    enum ThemeMode: String, CaseIterable, Identifiable {
        case follow = "follow"
        case light = "light"
        case dark = "dark"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .follow: return "跟随系统"
            case .light:  return "浅色"
            case .dark:   return "深色"
            }
        }
    }

    enum LaunchBehavior: String, CaseIterable, Identifiable {
        case newCard = "newCard"
        case lastState = "lastState"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .newCard:   return "新建卡片"
            case .lastState: return "恢复上次状态"
            }
        }
    }

    // MARK: - 主题

    /// 应用主题 — 写到 UserDefaults 并设到 NSApp；窗口创建时会跟随 NSApp.appearance
    @MainActor
    static func applyTheme(_ mode: ThemeMode) {
        let appearance: NSAppearance?
        switch mode {
        case .follow: appearance = nil
        case .light:  appearance = NSAppearance(named: .aqua)
        case .dark:   appearance = NSAppearance(named: .darkAqua)
        }
        UserDefaults.standard.set(mode.rawValue, forKey: themeKey)
        NSApp.appearance = appearance
    }

    /// 启动时恢复主题偏好
    @MainActor
    static func restoreThemeOnLaunch() {
        _ = applyTheme(theme)
    }

    static var theme: ThemeMode {
        get {
            ThemeMode(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "follow") ?? .follow
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
            applyTheme(newValue)
        }
    }

    // MARK: - 启动行为

    static var launchBehavior: LaunchBehavior {
        get {
            LaunchBehavior(rawValue: UserDefaults.standard.string(forKey: launchBehaviorKey) ?? "newCard") ?? .newCard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: launchBehaviorKey)
        }
    }

    // MARK: - 自动保存间隔

    static var autoSaveInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: autoSaveIntervalKey)
            return value > 0 ? value : 0.8
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoSaveIntervalKey)
        }
    }

    // MARK: - 回收站保留天数

    static var trashRetentionDays: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: trashRetentionDaysKey)
            return value > 0 ? value : 30
        }
        set {
            UserDefaults.standard.set(newValue, forKey: trashRetentionDaysKey)
        }
    }
}
