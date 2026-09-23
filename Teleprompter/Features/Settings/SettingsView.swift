import SwiftUI
import SwiftData

/// 设置页面
struct SettingsView: View {

    /// 设置变更回调（保存到 SwiftData 后通知外部同步 PIP）
    private let onSettingsChanged: (TeleprompterSettings) -> Void

    init(onSettingsChanged: @escaping (TeleprompterSettings) -> Void) {
        self.onSettingsChanged = onSettingsChanged
    }

    /// 当前屏幕宽度（用于计算 PIP 尺寸）
    private var screenWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    // MARK: - 数据

    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [SettingsModel]

    // MARK: - 本地状态
    @State private var fontSize: Double = Constants.defaultFontSize
    @State private var scrollSpeed: Double = Constants.defaultScrollSpeed
    @State private var pipWidth: Double = 100 // 默认 100%（最大宽度）
    @State private var pipHeight: Double = 500
    @State private var isVoiceMode: Bool = true
    @State private var voiceMultiplier: Double = 1.0
    @State private var pipOpacity: Double = 0.85
    @State private var textColorHex: String = "#000000"
    @State private var highlightColorHex: String = "#FFD700"

    // MARK: - 主体

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 提词显示
                Section("提词显示") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("字号: \(Int(fontSize))")
                            Spacer()
                            Text("预览")
                                .font(.system(size: fontSize))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $fontSize,
                            in: Constants.minFontSize...Constants.maxFontSize,
                            step: 2
                        ) {
                            Text("字号")
                        } onEditingChanged: { _ in
                            applySettings()
                        }
                        .tint(.accentColor)

                        HStack {
                            Text("小")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("大")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: 滚动
                Section("滚动控制") {
                    Picker("滚动模式", selection: $isVoiceMode) {
                        Text("语音同步").tag(true)
                        Text("手动调速").tag(false)
                    }
                    .onChange(of: isVoiceMode) { _, _ in
                        applySettings()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("语速: \(Int(scrollSpeed)) 字/分")
                            Spacer()
                        }
                        Slider(
                            value: $scrollSpeed,
                            in: Constants.minScrollSpeed...Constants.maxScrollSpeed,
                            step: 10
                        ) {
                            Text("语速")
                        } onEditingChanged: { _ in
                            applySettings()
                        }
                        .tint(.accentColor)

                        HStack {
                            Text("慢 (\(Int(Constants.minScrollSpeed)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("快 (\(Int(Constants.maxScrollSpeed)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if isVoiceMode {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("语音倍率: x\(String(format: "%.1f", voiceMultiplier))")
                                Spacer()
                            }
                            Slider(
                                value: $voiceMultiplier,
                                in: 0.5...3.0,
                                step: 0.1
                            ) {
                                Text("倍率")
                            } onEditingChanged: { _ in
                                applySettings()
                            }
                            .tint(.accentColor)

                            HStack {
                                Text("慢")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("快")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // MARK: 悬浮窗外观
                Section("悬浮窗外观") {
                    // 文本颜色选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文本颜色")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(PIPPresetColors.allColors, id: \.hex) { preset in
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Circle()
                                                .stroke(textColorHex == preset.hex ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                        .onTapGesture {
                                            textColorHex = preset.hex
                                            applySettings()
                                        }
                                }
                            }
                        }
                    }


                    // 高亮颜色选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已读高亮颜色")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(PIPPresetColors.highlightColors, id: \.hex) { preset in
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .stroke(highlightColorHex == preset.hex ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture {
                                        highlightColorHex = preset.hex
                                        applySettings()
                                    }
                            }
                        }
                    }
                }
                }

                // MARK: 主题
                Section("主题") {
                    Picker("外观模式", selection: Binding(
                        get: {
                            ThemeMode.allCases.first { $0.rawValue == settings.first?.themeModeRaw } ?? .system
                        },
                        set: { newMode in
                            // 先同步到 UserDefaults（无脑写，不受 SwiftData 影响）
                            UserDefaults.standard.set(newMode.rawValue, forKey: "themeMode")
                            // 再保存到 SwiftData（如果没有 settings 记录则创建）
                            if let s = settings.first {
                                s.themeMode = newMode
                            } else {
                                let s = SettingsModel()
                                s.themeMode = newMode
                                modelContext.insert(s)
                            }
                            try? modelContext.save()
                            applySettings()
                        }
                    )) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            HStack {
                                Image(systemName: mode.icon)
                                Text(mode.rawValue)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: 关于
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Constants.appVersion)
                            .foregroundColor(.secondary)
                    }
                }


            }
            .navigationTitle("设置")
            .onAppear {
                loadSettings()
            }
        }
    }

    // MARK: - 加载/保存

    private func loadSettings() {
        if let s = settings.first {
            fontSize = s.fontSize
            scrollSpeed = s.scrollSpeed
            pipWidth = s.pipWidth // 已经是百分比
            pipHeight = s.pipHeight
            isVoiceMode = s.isVoiceMode
            voiceMultiplier = s.voiceSpeedMultiplier
            pipOpacity = s.pipOpacity
            textColorHex = s.textColorHex
            highlightColorHex = s.highlightColorHex
        }
    }

    private func applySettings() {
        print("[SettingsView] applySettings: textColorHex=\(textColorHex) highlightHex=\(highlightColorHex) opacity=\(pipOpacity)")

        // 持久化（存储百分比，50~100）
        if let s = settings.first {
            s.fontSize = fontSize
            s.scrollSpeed = scrollSpeed
            s.pipWidth = pipWidth
            s.pipHeight = pipWidth * 5 / 6
            s.isVoiceMode = isVoiceMode
            s.voiceSpeedMultiplier = voiceMultiplier
            s.pipOpacity = pipOpacity
            s.textColorHex = textColorHex
            s.highlightColorHex = highlightColorHex
        } else {
            let s = SettingsModel(
                fontSize: fontSize,
                scrollSpeed: scrollSpeed,
                pipWidth: pipWidth,
                pipHeight: pipWidth * 5 / 6,
                isVoiceMode: isVoiceMode,
                voiceSpeedMultiplier: voiceMultiplier,
                highlightColorHex: highlightColorHex,
                pipOpacity: pipOpacity,
                textColorHex: textColorHex
            )
            modelContext.insert(s)
        }
        try? modelContext.save()

        // 获取当前主题
        let currentTheme = settings.first?.themeMode ?? .system

        let teleprompterSettings = TeleprompterSettings(
            fontSize: CGFloat(fontSize),
            scrollSpeed: scrollSpeed,
            pipWidth: pipWidth,
            pipHeight: pipWidth * 5 / 6, // 固定宽高比 6:5
            isVoiceMode: isVoiceMode,
            voiceSpeedMultiplier: voiceMultiplier,
            themeMode: currentTheme,
            highlightColor: UIColor(hexString: highlightColorHex) ?? .yellow,
            pipOpacity: CGFloat(pipOpacity),
            textColor: UIColor(hexString: textColorHex) ?? .white
        )
        onSettingsChanged(teleprompterSettings)
    }
}

// MARK: - 预置颜色

struct PIPPresetColor {
    let name: String
    let hex: String
    var color: Color { Color(hex: hex) ?? .white }
}

enum PIPPresetColors {
    /// 全部颜色（文本用）
    static let allColors: [PIPPresetColor] = [
        .init(name: "黑色", hex: "#000000"),
        .init(name: "深灰", hex: "#444444"),
        .init(name: "白色", hex: "#FFFFFF"),
        .init(name: "浅灰", hex: "#E0E0E0"),
        .init(name: "黄色", hex: "#FFD700"),
        .init(name: "橙色", hex: "#FF8C00"),
        .init(name: "红色", hex: "#FF4444"),
        .init(name: "粉色", hex: "#FF69B4"),
        .init(name: "绿色", hex: "#4CAF50"),
        .init(name: "蓝色", hex: "#42A5F5"),
    ]

    /// 高亮专用颜色（更鲜艳）
    static let highlightColors: [PIPPresetColor] = [
        .init(name: "金色", hex: "#FFD700"),
        .init(name: "橙色", hex: "#FF8C00"),
        .init(name: "亮红", hex: "#FF5252"),
        .init(name: "粉色", hex: "#FF69B4"),
        .init(name: "亮绿", hex: "#69F0AE"),
        .init(name: "天蓝", hex: "#40C4FF"),
        .init(name: "亮黄", hex: "#FFFF00"),
        .init(name: "白色", hex: "#FFFFFF"),
    ]
}
