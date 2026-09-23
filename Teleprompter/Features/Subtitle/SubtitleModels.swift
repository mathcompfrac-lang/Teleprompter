import CoreMedia
import Foundation

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
