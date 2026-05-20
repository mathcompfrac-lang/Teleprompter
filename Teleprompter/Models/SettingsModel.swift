import Foundation
import SwiftUI
import SwiftData

/// 主题模式
enum ThemeMode: String, CaseIterable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

@Model
final class SettingsModel {
    /// 字号
    var fontSize: Double
    /// 滚动速度（字/分钟）
    var scrollSpeed: Double
    /// 画中画窗口宽度
    var pipWidth: Double
    /// 画中画窗口高度
    var pipHeight: Double
    /// 滚动模式：true = 语音，false = 手动
    var isVoiceMode: Bool
    /// 语音模式下的速度倍率
    var voiceSpeedMultiplier: Double
    /// 主题模式
    var themeModeRaw: String = "system"
    /// PIP 高亮颜色（hex）
    var highlightColorHex: String = "#FFD700"
    /// PIP 背景透明度（0.3-1.0）
    var pipOpacity: Double = 0.85
    /// PIP 文本颜色（hex）
    var textColorHex: String = "#FFFFFF"

    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .system }
        set { themeModeRaw = newValue.rawValue }
    }

    init(
        fontSize: Double = 28,
        scrollSpeed: Double = 120,
        pipWidth: Double = 360,
        pipHeight: Double = 640,
        isVoiceMode: Bool = true,
        voiceSpeedMultiplier: Double = 1.0,
        themeMode: ThemeMode = .system,
        highlightColorHex: String = "#FFD700",
        pipOpacity: Double = 0.85,
        textColorHex: String = "#FFFFFF"
    ) {
        self.fontSize = fontSize
        self.scrollSpeed = scrollSpeed
        self.pipWidth = pipWidth
        self.pipHeight = pipHeight
        self.isVoiceMode = isVoiceMode
        self.voiceSpeedMultiplier = voiceSpeedMultiplier
        self.themeModeRaw = themeMode.rawValue
        self.highlightColorHex = highlightColorHex
        self.pipOpacity = pipOpacity
        self.textColorHex = textColorHex
    }
}
