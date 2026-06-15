//
//  MainView.swift
//  KaJi
//
//  主视图：macOS 15 原生两栏布局入口。
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var editorState: EditorState
    @Environment(\.undoManager) var undoManager

    var body: some View {
        NavigationSplitView(columnVisibility: $editorState.sidebarColumnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            editorState.undoManager = undoManager
        }
        .onDisappear {
            editorState.undoManager = nil
        }
    }
}
