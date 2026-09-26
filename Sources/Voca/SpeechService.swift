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

import AVFoundation

/// 发音口音
enum SpeechAccent: String, CaseIterable {
    case british = "en-GB"
    case american = "en-US"
}

/// 系统离线语音朗读（AVSpeechSynthesizer）。
///
/// 每种口音自动挑选系统内品质最高的语音：用户已下载神经/增强语音
/// （如 en-US Simone、en-GB Eddy）则直接用，否则降级到内置语音。
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()
    private var voices: [SpeechAccent: AVSpeechSynthesisVoice] = [:]

    private init() {
        for accent in SpeechAccent.allCases {
            voices[accent] = Self.bestVoice(for: accent.rawValue)
        }
    }

    /// 指定语言里品质最高的已安装语音；无候选时交给系统按语言回退
    private static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// 朗读文本；打断上一段正在朗读的内容
    func speak(_ text: String, accent: SpeechAccent) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = voices[accent] {
            utterance.voice = voice
        }
        // 单词朗读略慢于默认语速，便于听清
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// 立即停止朗读
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
