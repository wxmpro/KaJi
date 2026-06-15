//
//  SearchOverlay.swift
//  KaJi
//
//  右上角搜索浮层。
//

import SwiftUI

struct SearchOverlay: View {
    @EnvironmentObject var editorState: EditorState
    @EnvironmentObject var listState: ListState
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if editorState.isSearchActive {
                searchFieldView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            magnifierButton
        }
    }

    private var searchFieldView: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索卡片...", text: $editorState.searchKeyword)
                .textFieldStyle(.plain)
                .frame(width: 220)
                .focused($searchFocused)
                .onSubmit {
                    let keyword = editorState.searchKeyword.trimmingCharacters(in: .whitespaces)
                    guard !keyword.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        listState.showList(.search(keyword))
                    }
                }

            Button {
                editorState.searchKeyword = ""
                withAnimation(.easeInOut(duration: 0.15)) {
                    editorState.isSearchActive = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("清空并关闭")
            .kajiHover(cornerRadius: 6, restingBackground: .clear)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }

    private var magnifierButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                editorState.isSearchActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                searchFocused = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help("搜索卡片")
        .kajiHover(cornerRadius: 16, restingBackground: magnifierBackgroundColor)
        .overlay(
            Circle()
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }

    private var magnifierBackgroundColor: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}
