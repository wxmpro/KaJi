//
//  ContentView.swift
//  KaJi
//
//  ContentView — 空包装（被 KaJiApp.swift 里 AppDelegate 直接宿主 MainView）。
//  KaJiApp 启动时把 MainView 装进 NSHostingView，绕开 SwiftUI WindowGroup。
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
