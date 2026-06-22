//
//  UpdaterService.swift
//  KaJi
//
//  轻量在线更新检查（v1.10.2 起改为「检查 + 引导下载」模式）。
//
//  设计背景：
//  - 当前分发为 ad-hoc 签名（无 Apple Developer ID），Sparkle 的全自动「下载即安装」
//    会因代码签名一致性校验失败而无法落地。
//  - 因此这里改为自实现的轻量检查：拉取公开仓库的 appcast.xml → 比较 build 号 →
//    发现新版本时弹窗引导用户前往 GitHub 下载页手动安装（拖入「应用程序」覆盖）。
//  - 仓库（wxmpro/KaJi）公开，appcast 与 dmg 均可匿名下载。
//
//  保留项（未来铺垫，非死代码）：
//  - Info.plist 的 SUFeedURL / SUPublicEDKey 与 CI 的 EdDSA 签名流程保留。
//    一旦接入 Apple Developer ID 签名 + 公证，可无缝切回 Sparkle 全自动安装。
//
//  @MainActor @Observable 单例：SwiftUI 的 Toggle / Text 自动响应；UserDefaults 沿用 "KaJi." 前缀。
//

import Foundation
import AppKit

@MainActor
@Observable
final class UpdaterService {
    static let shared = UpdaterService()

    // MARK: - 常量

    /// 更新源：公开仓库的 appcast.xml（与 Info.plist 的 SUFeedURL 一致）
    private static let appcastURL = URL(string: "https://raw.githubusercontent.com/wxmpro/KaJi/main/appcast.xml")!
    /// 下载页：最新 release（用户手动下载安装）
    static let downloadPageURL = URL(string: "https://github.com/wxmpro/KaJi/releases/latest")!

    // MARK: - UserDefaults Keys（沿用旧 key，避免用户已有偏好丢失）

    private enum Keys {
        static let autoCheck = "KaJi.updater.autoCheck"
        static let autoOpen = "KaJi.updater.autoDownload"
        static let lastCheck = "KaJi.updater.lastCheck"
    }

    // MARK: - 可观察属性（绑定到「关于」页两个开关）

    /// 自动检查更新：启动时后台检查一次
    var automaticallyChecksForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Keys.autoCheck) }
    }

    /// 发现新版本时是否自动打开下载页（关闭则仅弹提示，由用户点击「前往下载」）
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
        if d.object(forKey: Keys.autoOpen) == nil { d.set(false, forKey: Keys.autoOpen) }
        automaticallyChecksForUpdates = d.bool(forKey: Keys.autoCheck)
        automaticallyDownloadsUpdates = d.bool(forKey: Keys.autoOpen)
        lastUpdateCheckDate = d.object(forKey: Keys.lastCheck) as? Date
    }

    // MARK: - 启动钩子

    /// applicationDidFinishLaunching 调用：开启自动检查时后台静默检查一次
    func start() {
        guard automaticallyChecksForUpdates else { return }
        Task { await performCheck(userInitiated: false) }
    }

    // MARK: - 公共 API

    /// 手动「检查更新…」按钮触发
    func checkForUpdates() {
        Task { await performCheck(userInitiated: true) }
    }

    /// 当前版本号字符串（"1.10.2 (53)"）
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
                    NSWorkspace.shared.open(Self.downloadPageURL)
                } else {
                    presentUpdateAvailable(shortVersion: latest.short)
                }
            } else if userInitiated {
                presentAlert(title: "已是最新版本", text: "你当前使用的 \(currentVersionString) 已是最新版本。")
            }
        } catch {
            if userInitiated { presentAlert(title: "检查更新失败", text: error.localizedDescription) }
        }
    }

    /// 解析 appcast.xml，返回 build 号最大的版本 (build, shortVersion)
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

    private func presentUpdateAvailable(shortVersion: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(shortVersion)"
        alert.informativeText = "当前版本 \(currentVersionString)。点击「前往下载」获取最新版本，下载后拖入「应用程序」覆盖即可。"
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
