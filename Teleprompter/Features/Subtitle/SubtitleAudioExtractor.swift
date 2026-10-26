import AVFoundation
import Foundation

struct ExtractedSubtitleAudio: Sendable {
    let url: URL
    let timelineOffset: CMTime
}

/// 为不同字幕引擎准备同一份音频文件，保证 A/B 对比使用一致输入。
final class SubtitleAudioExtractor: @unchecked Sendable {
    static let shared = SubtitleAudioExtractor()

    private init() {}

    func extractAudio(from videoURL: URL) async throws -> ExtractedSubtitleAudio {
        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                error.localizedDescription
            )
        }

        guard let audioTrack = tracks.first else {
            throw LocalSubtitleTranscriptionError.noAudioTrack
        }

        let audioTimeRange: CMTimeRange
        do {
            audioTimeRange = try await audioTrack.load(.timeRange)
        } catch {
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                error.localizedDescription
            )
        }
        guard audioTimeRange.isValid,
              !audioTimeRange.isEmpty,
              audioTimeRange.start.isNumeric,
              audioTimeRange.duration.isNumeric else {
            throw LocalSubtitleTranscriptionError.emptyAudio
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeleprompterSubtitle", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                error.localizedDescription
            )
        }

        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let audioComposition = AVMutableComposition()
        guard let compositionTrack = audioComposition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                "Could not create an audio composition track."
            )
        }
        do {
            try compositionTrack.insertTimeRange(
                audioTimeRange,
                of: audioTrack,
                at: .zero
            )
        } catch {
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                error.localizedDescription
            )
        }

        guard let exportSession = AVAssetExportSession(
            asset: audioComposition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                "AVAssetExportSession could not be created."
            )
        }

        do {
            if #available(iOS 18.0, *) {
                try await exportSession.export(to: destination, as: .m4a)
            } else {
                try await exportForIOS17(exportSession, to: destination)
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                error.localizedDescription
            )
        }

        return ExtractedSubtitleAudio(
            url: destination,
            timelineOffset: audioTimeRange.start
        )
    }

    @available(iOS, introduced: 17.0, obsoleted: 18.0)
    private func exportForIOS17(
        _ exportSession: AVAssetExportSession,
        to destination: URL
    ) async throws {
        exportSession.outputURL = destination
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .failed:
                        continuation.resume(
                            throwing: exportSession.error
                                ?? LocalSubtitleTranscriptionError.audioExtractionFailed(
                                    "AVAssetExportSession failed."
                                )
                        )
                    default:
                        continuation.resume(
                            throwing: LocalSubtitleTranscriptionError.audioExtractionFailed(
                                "AVAssetExportSession finished in an unexpected state."
                            )
                        )
                    }
                }
            }
        }, onCancel: {
            exportSession.cancelExport()
        })
    }
}
