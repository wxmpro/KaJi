//
//  SettingsView.swift
//  KaJi
//
//  设置窗口：macOS 原生 Tab 风格。
//  v1.0 仅包含「通用」标签：主题、数据路径、版本。
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("KaJi.theme") private var themeSetting: String = "follow"

    private var selectedTheme: SettingsService.ThemeMode {
        get {
            switch themeSetting {
            case "light": return .light
            case "dark":  return .dark
            default:      return .follow
            }
        }
        nonmutating set {
            switch newValue {
            case .follow: themeSetting = "follow"
            case .light:  themeSetting = "light"
            case .dark:   themeSetting = "dark"
            }
            SettingsService.applyTheme(newValue)
        }
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
        }
        .frame(width: 420, height: 240)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker("外观主题：", selection: Binding(
                    get: { selectedTheme },
                    set: { selectedTheme = $0 }
                )) {
                    Text("跟随系统").tag(SettingsService.ThemeMode.follow)
                    Text("浅色").tag(SettingsService.ThemeMode.light)
                    Text("深色").tag(SettingsService.ThemeMode.dark)
                }
                .pickerStyle(.radioGroup)
                .padding(.bottom, 4)

                HStack(alignment: .firstTextBaseline) {
                    Text("数据位置：")
                        .frame(width: 72, alignment: .trailing)
                    Text(databasePath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(databasePath)
                }
                .padding(.vertical, 2)

                HStack {
                    Spacer()
                    Text("卡迹 KaJi \(appVersion) (\(buildNumber))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    /// 当前数据库文件路径（in-memory 模式下显示提示）
    private var databasePath: String {
        if AppDatabase.shared.isInMemory {
            return "内存模式（无文件）"
        }
        return AppDatabase.dbURL.path
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
