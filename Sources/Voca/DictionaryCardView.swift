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

/// 查词浮窗内的词典卡片：词头、音标、英/美发音、释义与标签。
/// 内容过长时释义区内部滚动，卡片整体不撑开容器。
/// 只渲染内容，浮层材质由容器提供（LookupPopupView 的 `floatingSurface`）。
extension DictionaryEnrichment.RootPart {
    /// 徽章角色色：后缀紫（"-ion" 类）、前缀橙（"in-1" 类）、词根强调色
    var badgeColor: Color {
        if key.hasPrefix("-") { return .purple }
        if key.contains("-") { return .orange }
        return .accentColor
    }
}

struct DictionaryCardView: View {
    let result: DictionaryLookupResult
    @AppStorage("popupFontSize") private var popupFontSize = Typography.popupDefault
    /// 释义与学习区块的阅读区高度（设置滑杆直接控制，浮窗总高随此值联动）
    @AppStorage("popupReadingHeight") private var readingHeight = 148.0

    private var entry: DictionaryEntry { result.entry }

    var body: some View {
        cardContent
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.word)
                    .font(.system(size: Typography.derived(popupFontSize, offset: 3), weight: .bold))
                Text(DictionaryService.prettifiedPhonetic(entry.phonetic))
                    .font(.system(size: popupFontSize))
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
            .frame(height: readingHeight)
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
                        accent == .british ? L10n.text("英") : L10n.text("美"),
                        systemImage: "speaker.wave.2"
                    )
                    .font(.system(size: popupFontSize))
                }
                .buttonStyle(.borderless)
                .help(accent == .british ? L10n.text("英音朗读") : L10n.text("美音朗读"))
            }
        }
    }

    // MARK: - 释义

    /// 词形变体（went）：先说明自身（"go的过去式"），再附原形词条；
    /// 释义：术语库补充区块置顶（与原释义并存，不覆盖）
    @ViewBuilder
    private var senses: some View {
        termSection
        if let lemma = result.lemma,
            lemma.word.lowercased() != entry.word.lowercased() {
            if !entry.translation.isEmpty {
                senseText(entry.translation, secondary: false)
            }
            Divider().padding(.vertical, 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(lemma.word)
                    .font(.system(size: Typography.derived(popupFontSize, offset: 1), weight: .bold))
                Text(DictionaryService.prettifiedPhonetic(lemma.phonetic))
                    .font(.system(size: Typography.derived(popupFontSize, offset: -2)))
                    .foregroundStyle(.secondary)
            }
            senseBlock(lemma)
        } else {
            senseBlock(entry)
        }
        enrichmentSections
        tagsRow
    }

    /// 术语库区块：中文释义＋可选英文说明（scripts/terms.csv 社区共建）
    @ViewBuilder
    private var termSection: some View {
        if let term = result.term {
            VStack(alignment: .leading, spacing: 3) {
                sectionLabel("术语")
                senseText(term.translation, secondary: false)
                if !term.definition.isEmpty {
                    senseText(term.definition, secondary: true)
                }
            }
            Divider().padding(.vertical, 1)
        }
    }

    // MARK: - 学习增强区块（词根/词形家族/相关短语/同义词）

    @ViewBuilder
    private var enrichmentSections: some View {
        if let e = result.enrichment {
            if !e.roots.isEmpty {
                Divider().padding(.vertical, 1)
                rootSection(e.roots)
            }
            if !e.family.isEmpty {
                Divider().padding(.vertical, 1)
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("词形家族")
                    Text(e.family.map { "\(L10n.text($0.label)) \($0.form)" }.joined(separator: " · "))
                        .font(.system(size: Typography.derived(popupFontSize, offset: -1)))
                        .textSelection(.enabled)
                }
            }
            if !e.phrases.isEmpty {
                Divider().padding(.vertical, 1)
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("相关短语")
                    Text(e.phrases.joined(separator: " / "))
                        .font(.system(size: Typography.derived(popupFontSize, offset: -1)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !e.synonyms.isEmpty {
                Divider().padding(.vertical, 1)
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("同义词")
                    Text(e.synonyms.prefix(8).joined(separator: ", "))
                        .font(.system(size: Typography.derived(popupFontSize, offset: -1)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func rootSection(_ roots: [DictionaryEnrichment.RootPart]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                sectionLabel("词根拆解")
                Text(roots.allSatisfy(\.direct) ? L10n.text("标注") : L10n.text("拆解"))
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            // 第一行：纯词根组合徽章（彩底白粗）相连；随后每行「徽章 + 释义」
            HStack(spacing: 4) {
                ForEach(Array(roots.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Text("+")
                            .font(.system(size: popupFontSize))
                            .foregroundStyle(.tertiary)
                    }
                    rootBadge(part, fontSize: popupFontSize)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(roots, id: \.key) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        rootBadge(part, fontSize: Typography.derived(popupFontSize, offset: -1))
                        Text(part.meaning.isEmpty ? "—" : part.meaning)
                            .font(.system(size: Typography.derived(popupFontSize, offset: -1)))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            let origin = roots.map(\.origin).filter { !$0.isEmpty }.sorted().first ?? ""
            let examples = roots.flatMap(\.examples)
                .filter { $0.lowercased() != entry.word.lowercased() }
            if !origin.isEmpty || !examples.isEmpty {
                Text(([origin.isEmpty ? nil : L10n.format("词源：%@", origin)]
                    + (examples.isEmpty ? [] : [L10n.format("同根：%@", examples.prefix(6).joined(separator: ", "))]))
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: Typography.derived(popupFontSize, offset: -2)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// 词根/词缀徽章：实色角色底 + 白色粗体
    private func rootBadge(
        _ part: DictionaryEnrichment.RootPart, fontSize: CGFloat
    ) -> some View {
        Text(part.displayName)
            .font(.system(size: fontSize, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(part.badgeColor))
            .foregroundStyle(.white)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
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
            .font(.system(size: popupFontSize))
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
            parts.append(L10n.text("柯林斯") + String(repeating: "★", count: entry.collins))
        }
        if entry.oxford == 1 {
            parts.append(L10n.text("牛津3000"))
        }
        parts.append(contentsOf: tags.map { L10n.text($0) })
        if entry.frq > 0 {
            parts.append(L10n.format("词频 #%d", entry.frq))
        } else if entry.bnc > 0 {
            parts.append(L10n.format("词频 #%d", entry.bnc))
        }
        return Group {
            if parts.isEmpty {
                EmptyView()
            } else {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
    }
}
