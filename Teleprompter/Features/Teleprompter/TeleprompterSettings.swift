import Foundation
import SwiftUI

/// 提词器运行时设置（不持久化，从 SettingsModel 加载）
struct TeleprompterSettings {
    var fontSize: CGFloat
    var scrollSpeed: Double       // 字/分钟
    var pipWidth: CGFloat
    var pipHeight: CGFloat
    var isVoiceMode: Bool
    var voiceSpeedMultiplier: Double
    var themeMode: ThemeMode
    var highlightColor: UIColor
    var pipOpacity: CGFloat
    var textColor: UIColor

    /// 滚动速度转每秒偏移量（基于字号估算）
    var scrollOffsetPerSecond: CGFloat {
        let charHeight = fontSize * 1.5 // 每字近似高度
        let charsPerSecond = scrollSpeed / 60.0
        return charHeight * CGFloat(charsPerSecond)
    }

    static let `default` = TeleprompterSettings(
        fontSize: 28,
        scrollSpeed: 120,
        pipWidth: 360,
        pipHeight: 640,
        isVoiceMode: true,
        voiceSpeedMultiplier: 1.0,
        themeMode: .system,
        highlightColor: UIColor(hexString: "#FFD700") ?? .yellow,
        pipOpacity: 0.85,
        textColor: .black
    )
}
