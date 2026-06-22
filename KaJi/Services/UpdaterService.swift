//
//  UpdaterService.swift
//  KaJi
//
//  自实现的在线更新检查（v1.11.3 起，替代 Sparkle）。
//
//  流程：
//  1. URLSession 拉取公开仓库的 appcast.xml
//  2. 正则解析取出最大 build 号的版本
//  3. 与当前 Bundle.main 的 CFBundleVersion 比较：
//     - 当前 >= 最新 → 不弹窗（除非用户手动触发）
//     - 当前 < 最新 → 弹窗「发现新版本」+「前往下载」按钮
//  4. 「前往下载」调用 NSWorkspace.shared.open 打开 GitHub release latest 页面
//
//  为什么不用 Sparkle 自动装：ad-hoc 签名 + Sparkle 自动装在 macOS 26 dyld 上会
//  因为 hardened runtime flag + universal framework 切片组合触发「different Team IDs」
//  SIGABRT，且修复路径需要 Apple Developer ID 签名。
// 当前选择：用浏览器打开下载页 + 用户手动拖入安装（牺牲一键自动装，换取不崩）。
//
//  设计：
//  - @MainActor @Observable 单例 — SwiftUI Toggle 自动响应
//  - UserDefaults keys 沿用 KaJi. 前缀
//  - 默认：自动检查 on / 自动打开下载页 on（启动发现新版时直接打开浏览器）
//  - 用户可关掉"自动打开下载页"——则只弹窗，由用户主动点"前往下载"按钮
//

import Foundation
import AppKit

@MainActor
@Observable
final class UpdaterService {
    static let shared = UpdaterService()

    // MARK: - 常量

    /// 更新源：公开仓库的 appcast.xml
    private static let appcastURL = URL(string: "https://raw.githubusercontent.com/wxmpro/KaJi/main/appcast.xml")!
    /// 下载页：最新 release（用户手动下载 dmg 后拖入应用程序）
    static let downloadPageURL = URL(string: "https://github.com/wxmpro/KaJi/releases/latest")!

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let autoCheck = "KaJi.updater.autoCheck"
        /// "自动打开下载页" —— v1.10.0 时代 key 名是 autoDownload，含义变了但 key 名沿用避免老用户偏好丢失
        static let autoOpen = "KaJi.updater.autoDownload"
        static let lastCheck = "KaJi.updater.lastCheck"
    }

    // MARK: - 可观察属性（绑定到「关于」页两个开关）

    /// 自动检查更新：启动 + 后台静默检查一次
    var automaticallyChecksForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Keys.autoCheck) }
    }

    /// 发现新版本时是否自动打开下载页（关闭则仅弹提示，由用户点「前往下载」）
    var automaticallyDownloadsUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyDownloadsUpdates, forKey: Keys.autoOpen) }
    }

    /// 上次检查时间（「关于」页只读显示）
    private(set) var lastUpdateCheckDate: Date?

    @ObservationIgnored
    private var isChecking = false

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.autoCheck) == nil { d.set(true, forKey: Keys.autoCheck) }
        if d.object(forKey: Keys.autoOpen) == nil { d.set(true, forKey: Keys.autoOpen) }
        automaticallyChecksForUpdates = d.bool(forKey: Keys.autoCheck)
        automaticallyDownloadsUpdates = d.bool(forKey: Keys.autoOpen)
        lastUpdateCheckDate = d.object(forKey: Keys.lastCheck) as? Date
    }

    // MARK: - 启动钩子

    /// AppDelegate.applicationDidFinishLaunching 调用：
    /// 自动检查开启时，启动后台静默检查一次
    func start() {
        guard automaticallyChecksForUpdates else { return }
        Task { await performCheck(userInitiated: false) }
    }

    // MARK: - 公共 API

    /// 手动「检查更新…」按钮触发
    func checkForUpdates() {
        Task { await performCheck(userInitiated: true) }
    }

    /// 当前版本号字符串（"1.11.3 (55)"）— About tab 显示
    var currentVersionString: String {
        let b = Bundle.main
        let short = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    // MARK: - 检查实现

    private func performCheck(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var req = URLRequest(url: Self.appcastURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: req)

            lastUpdateCheckDate = Date()
            UserDefaults.standard.set(lastUpdateCheckDate, forKey: Keys.lastCheck)

            guard let latest = Self.parseLatest(from: data) else {
                if userInitiated { presentAlert(title: "无法检查更新", text: "更新源解析失败，请稍后再试。") }
                return
            }

            if latest.build > currentBuild {
                if automaticallyDownloadsUpdates {
                    // 自动打开下载页：直接 NSWorkspace，不再弹窗打扰
                    NSWorkspace.shared.open(Self.downloadPageURL)
                } else {
                    presentUpdateAvailable(shortVersion: latest.short, build: latest.build)
                }
            } else if userInitiated {
                presentAlert(title: "已是最新版本", text: "你当前使用的 \(currentVersionString) 已是最新版本。")
            }
        } catch {
            if userInitiated {
                presentAlert(title: "检查更新失败", text: error.localizedDescription)
            }
        }
    }

    /// 解析 appcast.xml，返回 build 号最大的版本
    nonisolated private static func parseLatest(from data: Data) -> (build: Int, short: String)? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        // enclosure 中 sparkle:version="N" 在 sparkle:shortVersionString="X" 之前，二者可能跨行
        let pattern = #"sparkle:version="(\d+)"[^>]*?sparkle:shortVersionString="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = xml as NSString
        var best: (build: Int, short: String)?
        regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let build = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let short = ns.substring(with: match.range(at: 2))
            if best == nil || build > best!.build { best = (build, short) }
        }
        return best
    }

    // MARK: - 弹窗

    private func presentUpdateAvailable(shortVersion: String, build: Int) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(shortVersion) (build \(build))"
        alert.informativeText = "当前版本 \(currentVersionString)。点击「前往下载」打开 GitHub release 页面，下载 dmg 后拖入「应用程序」覆盖即可。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.downloadPageURL)
        }
    }

    private func presentAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}