//
//  UpdaterService.swift
//  KaJi
//
//  Sparkle 2.x 在线更新包装（v1.10.0 引入）。
//
//  设计原则：
//  1. @MainActor @Observable 单例 — SPUStandardUpdaterController 必须主线程构造
//     （Swift 6 严格隔离）；@Observable 让 SwiftUI Toggle / Text 自动响应
//  2. Info.plist 已带 SUFeedURL / SUEnableAutomaticChecks / SUAllowsAutomaticUpdates / SUPublicEDKey
//     （由 project.yml → xcodegen 注入），这里只覆盖「用户偏好」（自动检查开关）和「手动触发入口」
//  3. UserDefaults keys 沿用 SettingsService 的 "KaJi." 前缀
//  4. SUPublicEDKey 在 CI 端由 GitHub Secret SPARKLE_PUBLIC_KEY 灌入；本地 build 用占位符也能跑
//     （仅 Sparkle 校验会失败，不影响 UI 与手动检查触发）
//

import Foundation
import AppKit
import Sparkle

/// Sparkle 2.x 包装：@MainActor @Observable 单例 + SwiftUI 视图层绑定。
/// 持有 SPUStandardUpdaterController（其内部 Updater 自动开启后台轮询）。
@MainActor
@Observable
final class UpdaterService {
    static let shared = UpdaterService()

    // MARK: - UserDefaults Keys（沿用 KaJi. 前缀）

    private static let autoCheckKey = "KaJi.updater.autoCheck"
    private static let autoDownloadKey = "KaJi.updater.autoDownload"
    private static let lastCheckKey = "KaJi.updater.lastCheck"

    // MARK: - 底层控制器（@ObservationIgnored：不让 SwiftUI 追踪 Sparkle 内部状态）

    @ObservationIgnored
    private let controller: SPUStandardUpdaterController

    // MARK: - 可观察属性（暴露给 SwiftUI）

    /// 自动检查更新（启动 + 间隔检查）
    var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.autoCheckKey)
        }
    }

    /// 自动下载更新（后台静默下 dmg）
    var automaticallyDownloadsUpdates: Bool {
        didSet {
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            UserDefaults.standard.set(automaticallyDownloadsUpdates, forKey: Self.autoDownloadKey)
        }
    }

    /// 上次成功拉取 appcast.xml 的时间（只读 UI 显示）
    private(set) var lastUpdateCheckDate: Date?

    // MARK: - Init

    private init() {
        // startingUpdater: true 让 Sparkle 在 init 后立即开始后台轮询
        // updaterDelegate / userDriverDelegate 留 nil（用默认 UI 弹窗 + 默认 delegate）
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // 首次写入默认偏好（true）
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoCheckKey) == nil {
            defaults.set(true, forKey: Self.autoCheckKey)
        }
        if defaults.object(forKey: Self.autoDownloadKey) == nil {
            defaults.set(true, forKey: Self.autoDownloadKey)
        }

        // 同步偏好给底层 Sparkle updater
        let autoCheck = defaults.bool(forKey: Self.autoCheckKey)
        let autoDownload = defaults.bool(forKey: Self.autoDownloadKey)
        controller.updater.automaticallyChecksForUpdates = autoCheck
        controller.updater.automaticallyDownloadsUpdates = autoDownload

        self.automaticallyChecksForUpdates = autoCheck
        self.automaticallyDownloadsUpdates = autoDownload
        self.lastUpdateCheckDate = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: - 启动钩子

    /// applicationDidFinishLaunching 调用；订阅 appcast 拉取完成通知，记录 lastUpdateCheckDate
    func start() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.SUUpdaterDidFinishLoadingAppCast,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                self.lastUpdateCheckDate = now
                UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
            }
        }
    }

    // MARK: - 公共 API

    /// 手动触发"检查更新"（SettingsView 的"检查更新…"按钮 → Sparkle 弹窗）
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 当前版本号字符串（"1.10.0 (51)"）— 给 About tab 显示
    var currentVersionString: String {
        let app = Bundle.main
        let short = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}