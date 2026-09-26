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
import Translation

/// 翻译方向：英文→中文 或 中文→英文（由选中文本是否含汉字决定）
enum TranslationDirection {
    case englishToChinese
    case chineseToEnglish

    var source: Locale.Language {
        self == .englishToChinese
            ? Locale.Language(identifier: "en") : Locale.Language(identifier: "zh-Hans")
    }

    var target: Locale.Language {
        self == .englishToChinese
            ? Locale.Language(identifier: "zh-Hans") : Locale.Language(identifier: "en")
    }

    /// 根据文本是否含汉字选择方向
    static func forText(_ text: String) -> TranslationDirection {
        DictionaryService.containsCJK(text) ? .chineseToEnglish : .englishToChinese
    }
}

/// 系统翻译（macOS Translation 框架）：设备端离线、免费。
///
/// `TranslationSession` 依附 SwiftUI 视图生命周期（`.translationTask`），
/// 由 `TranslatorView` 挂载；首次使用某语言对时系统会自动提示下载语言包。
struct TranslatorView: View {
    let text: String
    let direction: TranslationDirection
    /// 译文就绪时回调（浮窗保存按钮把译文写进备注）
    var onResult: ((String) -> Void)? = nil

    @State private var config: TranslationSession.Configuration?
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let result {
                VStack(alignment: .leading, spacing: 4) {
                    Text("译文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                Label("翻译不可用（语言包未下载或系统不支持）", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("翻译中…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 每次弹窗新实例：设置配置即触发 translationTask
            config = TranslationSession.Configuration(
                source: direction.source,
                target: direction.target
            )
        }
        .translationTask(config) { session in
            do {
                let response = try await session.translate(text)
                result = response.targetText
                onResult?(response.targetText)
            } catch {
                failed = true
            }
        }
    }
}
