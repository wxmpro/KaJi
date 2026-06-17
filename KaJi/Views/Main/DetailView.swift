//
//  DetailView.swift
//  KaJi
//
//  右侧详情区：根据 rightPaneMode 切换 editor / list。
//  v1.4.0：@EnvironmentObject → @Environment
//

import SwiftUI

struct DetailView: View {
    @Environment(ListState.self) private var listState

    var body: some View {
        switch listState.rightPaneMode {
        case .editor:
            NotesEditor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .list:
            CardListView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
