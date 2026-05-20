import Foundation

enum Constants {
    // App 信息
    static let appName = "悬浮提词器"
    static let appVersion = "1.0.1"

    // 试用 - 免费使用次数（与 TicketManager 保持一致）
    static let maxFreeTrials = 7
    static let usageCountKey = "teleprompter_usage_count"
    static let freeUsesRemainingKey = "free_uses_remaining"

    // 默认设置
    static let defaultFontSize: CGFloat = 28
    static let defaultScrollSpeed: Double = 120 // 字/分钟
    static let defaultPIPWidth: CGFloat = 360
    static let defaultPIPHeight: CGFloat = 640
    static let minFontSize: CGFloat = 14
    static let maxFontSize: CGFloat = 72
    static let minScrollSpeed: Double = 30
    static let maxScrollSpeed: Double = 400

    // 语音检测
    static let speechThreshold: Float = 0.08
    static let silenceTimeout: TimeInterval = 0.8
    static let audioSampleRate: Double = 16000

    // UserDefaults Keys
    static let scrollModeKey = "teleprompter_scroll_mode"
    static let fontSizeKey = "teleprompter_font_size"
    static let scrollSpeedKey = "teleprompter_scroll_speed"
    static let lastOpenedScriptIdKey = "teleprompter_last_script_id"
}
