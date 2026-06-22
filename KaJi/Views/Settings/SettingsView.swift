//
//  SettingsView.swift
//  KaJi
//
//  设置窗口：顶部 tab 按钮 + 下方内容（参考 Apple Podcasts 风格）。
//  包含「通用」「高级」「关于」三个标签页。
//

import SwiftUI
import AppKit

private enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, cardTypes, advanced, about
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .cardTypes: "卡片类型"
        case .advanced: "高级"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .cardTypes: "rectangle.stack.badge.plus"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @AppStorage("KaJi.theme") private var themeRawValue: String = "follow"
    // autoSaveInterval / trashRetentionDays 走 SettingsService setter（@AppStorage 直写
    // UserDefaults 不触发 SettingsService 缓存更新，会导致设置改后 debounce 间隔不变）

    @Environment(UpdaterService.self) private var updater
    @State private var selectedTab: SettingsTab = .general

    private var autoSaveIntervalBinding: Binding<Double> {
        Binding(
            get: { SettingsService.autoSaveInterval },
            set: { SettingsService.autoSaveInterval = $0 }
        )
    }
    private var trashRetentionDaysBinding: Binding<Int> {
        Binding(
            get: { SettingsService.trashRetentionDays },
            set: { SettingsService.trashRetentionDays = $0 }
        )
    }

    private var theme: Binding<SettingsService.ThemeMode> {
        Binding(
            get: { SettingsService.ThemeMode(rawValue: themeRawValue) ?? .follow },
            set: {
                themeRawValue = $0.rawValue
                SettingsService.theme = $0
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    // MARK: - 顶部 tab 栏

    private var tabBar: some View {
        HStack(spacing: 12) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    isSelected: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general: generalTab
        case .cardTypes: CardTypeSettingsView()
        case .advanced: advancedTab
        case .about: aboutTab
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Picker("外观主题：", selection: theme) {
                    ForEach(SettingsService.ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("设置会立即生效，并保存到本机。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("外观")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                Picker("自动保存间隔：", selection: autoSaveIntervalBinding) {
                    Text("0.5 秒").tag(0.5)
                    Text("0.8 秒").tag(0.8)
                    Text("1.2 秒").tag(1.2)
                    Text("2.0 秒").tag(2.0)
                }
                .pickerStyle(.segmented)

                Text("卡片停止编辑后，经过此间隔自动写入本地数据库。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("编辑")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    // MARK: - 高级

    private var advancedTab: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("数据位置：")
                        .frame(width: 76, alignment: .trailing)

                    Text(databasePath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(databasePath)

                    Spacer()

                    Button("在 Finder 中打开") {
                        openDatabaseFolder()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("数据")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                Picker("回收站保留天数：", selection: trashRetentionDaysBinding) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("永不清理").tag(0)
                }
                .pickerStyle(.segmented)

                Text("超过此天数的回收站卡片会在 App 启动时被彻底删除。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("回收站")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    // MARK: - 关于

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("卡迹 KaJi")
                        .font(.system(size: 18, weight: .semibold))

                    Text("版本 \(appVersion) (\(buildNumber))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let last = updater.lastUpdateCheckDate {
                        Text("上次检查：\(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("macOS 原生卡片笔记")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // === Sparkle 偏好（@Bindable 子 scope，避免污染根 view） ===
                @Bindable var updaterBindable = updater

                Toggle("自动检查更新", isOn: $updaterBindable.automaticallyChecksForUpdates)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: 240)

                Toggle("自动下载更新", isOn: $updaterBindable.automaticallyDownloadsUpdates)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: 240)
                    .disabled(!updater.automaticallyChecksForUpdates)

                // === Sparkle 手动检查（弹窗形式） ===
                Button("检查更新…") {
                    updater.checkForUpdates()
                }
                .controlSize(.small)
                .padding(.top, 4)
                .help("Sparkle 会在新窗口显示可用更新与发行说明")

                Button("查看发行说明") {
                    if let url = URL(string: "https://github.com/wxmpro/KaJi-macOS/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.link)
                .font(.system(size: 11))

                Text("© 2026 KaJi. All rights reserved.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    // MARK: - 辅助

    /// 当前数据库文件路径（in-memory 模式下显示提示）
    private var databasePath: String {
        if AppDatabase.shared.isInMemory {
            return "内存模式（无文件）"
        }
        do {
            return try AppDatabase.dbURL().path
        } catch {
            return "无法获取（\(error.localizedDescription)）"
        }
    }

    private func openDatabaseFolder() {
        let url: URL
        if AppDatabase.shared.isInMemory {
            url = FileManager.default.homeDirectoryForCurrentUser
        } else {
            url = (try? AppDatabase.dbURL().deletingLastPathComponent())
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    /// 版本号（从 Bundle 读取）
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

// MARK: - 顶部 tab 按钮

/// 顶部 tab 按钮：图标在上、文字在下；选中态有圆角矩形背景 + 强调色。
/// 参考 Apple Podcasts 设置窗口的「通用 / 播放 / 高级」三按钮风格。
private struct SettingsTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(width: 68, height: 44)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

#Preview {
    SettingsView()
}
