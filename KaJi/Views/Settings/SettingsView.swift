//
//  SettingsView.swift
//  KaJi
//
//  设置窗口：macOS 原生 Tab 风格。
//  包含「通用」「高级」「关于」三个标签页。
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("KaJi.theme") private var themeRawValue: String = "follow"
    @AppStorage("KaJi.autoSaveInterval") private var autoSaveInterval: Double = 0.8
    @AppStorage("KaJi.trashRetentionDays") private var trashRetentionDays: Int = 30

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
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            advancedTab
                .tabItem {
                    Label("高级", systemImage: "wrench.and.screwdriver")
                }

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 560, height: 400)
        .padding()
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
                Picker("自动保存间隔：", selection: $autoSaveInterval) {
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
                Picker("回收站保留天数：", selection: $trashRetentionDays) {
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
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("卡迹 KaJi")
                    .font(.system(size: 20, weight: .semibold))

                Text("版本 \(appVersion) (\(buildNumber))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("macOS 原生卡片笔记")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button("检查更新") {
                guard let url = URL(string: "https://github.com/wxmpro/KaJi-macOS/releases") else { return }
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
            .padding(.top, 8)

            Spacer()

            Text("© 2026 KaJi. All rights reserved.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 辅助

    /// 当前数据库文件路径（in-memory 模式下显示提示）
    /// v1.2.9 S1 修复：dbURL 改 throws；失败时返回友好提示
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
            // v1.2.9 S1 修复：fallback 到 home 目录
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

#Preview {
    SettingsView()
}
