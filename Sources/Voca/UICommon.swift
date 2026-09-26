// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
// General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// 跨界面共享的界面常量与基础控件。
///
/// 词库/剪贴板列表、查词浮窗与词条卡、星图三类表面此前各自维护字号派生、
/// 圆角与浮层材质，这里收拢成单一来源，避免同类控件再次各写一套。

/// 字号：两档用户设置（列表 / 浮窗）及其相对派生规则
enum Typography {
    static let listDefault = 13.0
    static let popupDefault = 13.0
    /// 两档滑杆的取值区间
    static let range = 11.0...18.0
    /// 派生字号下限：二元相对字号（音标 -2 等）在 11pt 设置下不得跌破此值
    static let minimum = 11.0

    /// 以基准字号加偏移派生，并夹住可读下限
    static func derived(_ base: Double, offset: Double) -> CGFloat {
        CGFloat(max(minimum, base + offset))
    }

    /// 星图界面文字（属性轨道、注释、顶栏标题）跟随「文字大小」滑块的倍率。
    /// 球面文字允许 0.5–2.5 倍；界面文字只在受控区间内缩放，避免极端倍率撑坏排版。
    static func galaxyChromeScale(_ fontScale: Double) -> CGFloat {
        CGFloat(min(max(fontScale, 0.85), 1.5))
    }
}

/// 圆角：按容器角色取值，不再逐处写字面量
enum Radius {
    /// 内联小容器：编辑框、图片缩略图
    static let inline: CGFloat = 8
    /// 卡片与浮层：查词浮窗、Toast、词条卡、星图注释与属性轨道
    static let card: CGFloat = 12
    /// 大面板：星图调参面板、双层过渡玻璃壳
    static let panel: CGFloat = 16
}

/// 手绘浮层材质：与星图的 glassEffect 并列的第二种浮层语言。
/// 查词浮窗、Toast、词条卡此前各写一份材质与阴影，这里统一为单一来源。
struct FloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.20), radius: 9, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

extension View {
    func floatingSurface(cornerRadius: CGFloat = Radius.card) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius))
    }
}

/// 文本当前宽度下是否会被行数上限截断
enum TextMetrics {
    static func exceedsLineLimit(
        _ text: String,
        fontSize: Double,
        maxLines: Int,
        width: CGFloat
    ) -> Bool {
        guard width > 0, maxLines > 0, !text.isEmpty else { return false }
        let font = NSFont.systemFont(ofSize: fontSize)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let lineHeight = font.ascender - font.descender + font.leading
        return measured > lineHeight * CGFloat(maxLines) + 1
    }
}

/// 行内截断探测：读取文本所在宽度后判定是否触发行数上限，
/// 列表行据此决定是否显示展开按钮（此前无论文本长短都显示）。
struct TruncationProbe: View {
    let text: String
    let fontSize: Double
    let maxLines: Int
    @Binding var isTruncated: Bool

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    update(width: width)
                }
                .onChange(of: text) { _, _ in update(width: geometry.size.width) }
                .onChange(of: fontSize) { _, _ in update(width: geometry.size.width) }
        }
    }

    private func update(width: CGFloat) {
        let truncated = TextMetrics.exceedsLineLimit(
            text, fontSize: fontSize, maxLines: maxLines, width: width
        )
        guard truncated != isTruncated else { return }
        // 布局阶段不直接写状态，避免 SwiftUI 的视图更新中进行状态变更
        DispatchQueue.main.async { isTruncated = truncated }
    }
}
