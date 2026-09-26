// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// 编辑面板顶部的词典卡片：词头、音标、英/美发音、释义与标签。
/// 内容过长时释义区内部滚动，卡片整体不撑开容器。
/// 查词浮窗以 `showsBackground: false` 复用，由容器自行提供背景。
struct DictionaryCardView: View {
    let result: DictionaryLookupResult
    var showsBackground = true

    private var entry: DictionaryEntry { result.entry }

    var body: some View {
        if showsBackground {
            cardContent
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.word)
                    .font(.title3)
                    .bold()
                Text(DictionaryService.prettifiedPhonetic(entry.phonetic))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                speakButtons
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    senses
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 148)
        }
    }

    // MARK: - 发音

    private var speakButtons: some View {
        HStack(spacing: 6) {
            ForEach(SpeechAccent.allCases, id: \.rawValue) { accent in
                Button {
                    SpeechService.shared.speak(entry.word, accent: accent)
                } label: {
                    Label(
                        accent == .british ? "英" : "美",
                        systemImage: "speaker.wave.2"
                    )
                    .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(accent == .british ? "英音朗读" : "美音朗读")
            }
        }
    }

    // MARK: - 释义

    /// 词形变体（went）：先说明自身（"go的过去式"），再附原形词条；
    /// 原形词：直接展示中文/英文释义
    @ViewBuilder
    private var senses: some View {
        if let lemma = result.lemma,
            lemma.word.lowercased() != entry.word.lowercased() {
            if !entry.translation.isEmpty {
                senseText(entry.translation, secondary: false)
            }
            Divider().padding(.vertical, 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(lemma.word)
                    .font(.callout)
                    .bold()
                Text(DictionaryService.prettifiedPhonetic(lemma.phonetic))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            senseBlock(lemma)
        } else {
            senseBlock(entry)
        }
        tagsRow
    }

    @ViewBuilder
    private func senseBlock(_ e: DictionaryEntry) -> some View {
        if !e.translation.isEmpty {
            senseText(e.translation, secondary: false)
        }
        if !e.definition.isEmpty {
            senseText(e.definition, secondary: true)
        }
    }

    /// 释义文本：ECDICT 以字面 "\n" 分隔义项，展示时转为换行；可选中复制
    private func senseText(_ raw: String, secondary: Bool) -> some View {
        Text(DictionaryService.displayText(raw))
            .font(.system(size: 13))
            .foregroundStyle(secondary ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - 标签

    private var tagsRow: some View {
        let tags = DictionaryService.localizedTags(entry.tag)
        var parts: [String] = []
        if entry.collins > 0 {
            parts.append("柯林斯" + String(repeating: "★", count: entry.collins))
        }
        if entry.oxford == 1 {
            parts.append("牛津3000")
        }
        parts.append(contentsOf: tags)
        if entry.frq > 0 {
            parts.append("词频 #\(entry.frq)")
        } else if entry.bnc > 0 {
            parts.append("词频 #\(entry.bnc)")
        }
        return Group {
            if parts.isEmpty {
                EmptyView()
            } else {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }
}
