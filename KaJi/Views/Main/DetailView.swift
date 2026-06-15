//
//  DetailView.swift
//  KaJi
//
//  右侧详情区：根据 rightPaneMode 切换 editor / list。
//

import SwiftUI

struct DetailView: View {
    @EnvironmentObject var listState: ListState

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
