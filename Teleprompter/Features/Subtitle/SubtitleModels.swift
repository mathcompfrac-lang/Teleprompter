import CoreMedia
import Foundation

enum SubtitleRecognitionLanguage: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case chinese
    case english
    case bilingual

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .chinese:
            return String(localized: "中文")
        case .english:
            return String(localized: "英文")
        case .bilingual:
            return String(localized: "中英混合")
        }
    }

    var localeIdentifiers: [String] {
        switch self {
        case .chinese:
            return ["zh-CN"]
        case .english:
            return ["en-US"]
        case .bilingual:
            return ["zh-CN", "en-US"]
        }
    }
}

enum SubtitleRecognitionEngine: String, Equatable, Sendable {
    case speechTranscriber = "SpeechTranscriber"
    case dictationTranscriber = "DictationTranscriber"
}

enum SubtitleRecognitionProvider: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case apple
    case senseVoice
    case qwen

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .apple:
            return String(localized: "Apple 本地识别")
        case .senseVoice:
            return String(localized: "SenseVoice 中文增强")
        case .qwen:
            return String(localized: "Qwen 云端识别")
        }
    }
}

enum SubtitleRecognitionMode: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case apple
    case senseVoice
    case qwen
    case comparison

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .apple:
            return String(localized: "Apple 本地识别")
        case .senseVoice:
            return String(localized: "SenseVoice 中文增强")
        case .qwen:
            return String(localized: "Qwen 云端识别")
        case .comparison:
            return String(localized: "多引擎对比")
        }
    }

    var requiresSenseVoiceModel: Bool {
        self == .senseVoice || self == .comparison
    }

    var requiresIOS26: Bool {
        self == .apple
    }

    var requiresQwenAPI: Bool {
        self == .qwen || self == .comparison
    }

    var usesReferenceText: Bool {
        self == .apple
    }

    var uploadsAudioToCloud: Bool {
        requiresQwenAPI
    }
}

struct SubtitleRecognitionRoute: Equatable, Sendable {
    let engine: SubtitleRecognitionEngine
    let localeIdentifier: String
}

struct SubtitleRecognitionMetadata: Equatable, Sendable {
    let provider: SubtitleRecognitionProvider
    let routes: [SubtitleRecognitionRoute]
    let referenceGuidedSelections: Int
    let modelIdentifier: String?
    let recognitionDuration: TimeInterval?

    init(
        provider: SubtitleRecognitionProvider = .apple,
        routes: [SubtitleRecognitionRoute] = [],
        referenceGuidedSelections: Int = 0,
        modelIdentifier: String? = nil,
        recognitionDuration: TimeInterval? = nil
    ) {
        self.provider = provider
        self.routes = routes
        self.referenceGuidedSelections = referenceGuidedSelections
        self.modelIdentifier = modelIdentifier
        self.recognitionDuration = recognitionDuration
    }

    var summary: String {
        switch provider {
        case .apple:
            return routes
                .map { "\($0.engine.rawValue) · \($0.localeIdentifier)" }
                .joined(separator: " / ")
        case .senseVoice:
            return modelIdentifier.map { "SenseVoice · \($0)" } ?? "SenseVoice"
        case .qwen:
            return modelIdentifier.map { "Qwen · \($0)" } ?? "Qwen"
        }
    }
}

struct SubtitleTranscriptionResult: Equatable, Sendable {
    let cues: [SubtitleCue]
    let metadata: SubtitleRecognitionMetadata
}

struct SubtitleRecognitionCandidate: Identifiable, Equatable, Sendable {
    let provider: SubtitleRecognitionProvider
    let result: SubtitleTranscriptionResult

    var id: SubtitleRecognitionProvider { provider }

    var recognitionDuration: TimeInterval? {
        result.metadata.recognitionDuration
    }
}

struct SubtitleRecognitionFailure: Identifiable, Equatable, Sendable {
    let provider: SubtitleRecognitionProvider
    let message: String

    var id: SubtitleRecognitionProvider { provider }
}

struct SubtitleTranscriptionBatchResult: Equatable, Sendable {
    let candidates: [SubtitleRecognitionCandidate]
    let selectedProvider: SubtitleRecognitionProvider
    let failures: [SubtitleRecognitionFailure]

    init(
        candidates: [SubtitleRecognitionCandidate],
        selectedProvider: SubtitleRecognitionProvider,
        failures: [SubtitleRecognitionFailure] = []
    ) {
        self.candidates = candidates
        self.selectedProvider = selectedProvider
        self.failures = failures
    }

    var selectedCandidate: SubtitleRecognitionCandidate? {
        candidates.first(where: { $0.provider == selectedProvider }) ?? candidates.first
    }
}

/// 一条与源视频时间轴对齐的字幕。
struct SubtitleCue: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var timeRange: CMTimeRange
    var text: String

    init(id: UUID = UUID(), timeRange: CMTimeRange, text: String) {
        self.id = id
        self.timeRange = timeRange
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(id: UUID = UUID(), startSeconds: Double, endSeconds: Double, text: String) {
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds > startSeconds else {
            return nil
        }
        self.init(
            id: id,
            timeRange: CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                end: CMTime(seconds: endSeconds, preferredTimescale: 600)
            ),
            text: text
        )
    }

    var startTime: CMTime {
        timeRange.start
    }

    var endTime: CMTime {
        CMTimeRangeGetEnd(timeRange)
    }

    var startSeconds: Double {
        startTime.seconds
    }

    var endSeconds: Double {
        endTime.seconds
    }

    var isValid: Bool {
        !text.isEmpty
            && startSeconds.isFinite
            && endSeconds.isFinite
            && startSeconds >= 0
            && endSeconds > startSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startSeconds
        case endSeconds
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        let endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        let text = try container.decode(String.self, forKey: .text)
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds > startSeconds else {
            throw DecodingError.dataCorruptedError(
                forKey: .endSeconds,
                in: container,
                debugDescription: "Subtitle time range is invalid."
            )
        }
        guard let cue = SubtitleCue(
            id: id,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .endSeconds,
                in: container,
                debugDescription: "Subtitle time range is invalid."
            )
        }
        self = cue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startSeconds, forKey: .startSeconds)
        try container.encode(endSeconds, forKey: .endSeconds)
        try container.encode(text, forKey: .text)
    }
}

enum SubtitleTranscriptionPhase: String, Equatable, Sendable {
    case checkingAvailability
    case preparingModel
    case extractingAudio
    case transcribing
    case completed
}

struct SubtitleTranscriptionProgress: Equatable, Sendable {
    let phase: SubtitleTranscriptionPhase
    let fractionCompleted: Double

    init(phase: SubtitleTranscriptionPhase, fractionCompleted: Double) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted.isFinite
            ? min(max(fractionCompleted, 0), 1)
            : 0
    }
}

enum LocalSubtitleTranscriptionError: Error, Equatable, Sendable {
    case requiresIOS26
    case engineUnavailable
    case unsupportedLocale(String)
    case videoFileNotFound
    case noAudioTrack
    case audioExtractionFailed(String)
    case modelInstallationFailed(String)
    case senseVoiceModelNotInstalled
    case senseVoiceModelInvalid
    case qwenAPIKeyMissing
    case audioLoadFailed(String)
    case emptyAudio
    case emptyTranscript
    case recognitionFailed(String)
}

extension LocalSubtitleTranscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .requiresIOS26:
            return "本地视频字幕识别需要 iOS 26 或更高版本。"
        case .engineUnavailable:
            return "当前设备不支持本地视频字幕识别。"
        case .unsupportedLocale(let identifier):
            return "当前设备不支持 \(identifier) 本地语音识别。"
        case .videoFileNotFound:
            return "找不到待识别的视频文件。"
        case .noAudioTrack:
            return "视频中没有可识别的音轨。"
        case .audioExtractionFailed(let reason):
            return "提取视频音轨失败：\(reason)"
        case .modelInstallationFailed(let reason):
            return "准备本地语音模型失败：\(reason)"
        case .senseVoiceModelNotInstalled:
            return String(localized: "请先下载 SenseVoice 模型。")
        case .senseVoiceModelInvalid:
            return String(localized: "SenseVoice 模型校验失败，请重新下载。")
        case .qwenAPIKeyMissing:
            return String(localized: "请先配置 Qwen API Key。")
        case .audioLoadFailed(let reason):
            return "读取视频音轨失败：\(reason)"
        case .emptyAudio:
            return "视频音轨为空。"
        case .emptyTranscript:
            return "没有从视频语音中识别到字幕。"
        case .recognitionFailed(let reason):
            return "本地字幕识别失败：\(reason)"
        }
    }
}
