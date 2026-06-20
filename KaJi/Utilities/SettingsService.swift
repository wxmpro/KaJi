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

    // MARK: - 自动保存间隔

    // 缓存 UserDefaults 值，避免每次 debounce 都 double 读 + > 0 判断
    // 首次 getter 从 UserDefaults 读，后续 getter 直接返回 cache；
    // setter 同时更新 cache 和 UserDefaults
    private static var cachedAutoSaveInterval: TimeInterval = 0.8
    private static var autoSaveIntervalLoaded: Bool = false

    static var autoSaveInterval: TimeInterval {
        get {
            if !autoSaveIntervalLoaded {
                let value = UserDefaults.standard.double(forKey: autoSaveIntervalKey)
                cachedAutoSaveInterval = value > 0 ? value : 0.8
                autoSaveIntervalLoaded = true
            }
            return cachedAutoSaveInterval
        }
        set {
            cachedAutoSaveInterval = newValue > 0 ? newValue : 0.8
            autoSaveIntervalLoaded = true
            UserDefaults.standard.set(newValue, forKey: autoSaveIntervalKey)
        }
    }

    // MARK: - 回收站保留天数

    // 缓存 UserDefaults 值，策略与 autoSaveInterval 一致
    private static var cachedTrashRetentionDays: Int = 30
    private static var trashRetentionDaysLoaded: Bool = false

    static var trashRetentionDays: Int {
        get {
            if !trashRetentionDaysLoaded {
                let value = UserDefaults.standard.integer(forKey: trashRetentionDaysKey)
                cachedTrashRetentionDays = value > 0 ? value : 30
                trashRetentionDaysLoaded = true
            }
            return cachedTrashRetentionDays
        }
        set {
            cachedTrashRetentionDays = newValue > 0 ? newValue : 30
            trashRetentionDaysLoaded = true
            UserDefaults.standard.set(newValue, forKey: trashRetentionDaysKey)
        }
    }
}
