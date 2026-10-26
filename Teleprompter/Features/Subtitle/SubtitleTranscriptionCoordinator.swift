import Foundation

/// 串行调度 Apple、SenseVoice 与 Qwen，对比模式下复用同一份已提取音频。
final class SubtitleTranscriptionCoordinator: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SubtitleTranscriptionProgress) -> Void

    static let shared = SubtitleTranscriptionCoordinator()

    private init() {}

    func transcribeVideo(
        at videoURL: URL,
        mode: SubtitleRecognitionMode,
        language: SubtitleRecognitionLanguage,
        referenceText: String,
        progress: ProgressHandler? = nil
    ) async throws -> SubtitleTranscriptionBatchResult {
        progress?(SubtitleTranscriptionProgress(
            phase: .checkingAvailability,
            fractionCompleted: 0
        ))
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LocalSubtitleTranscriptionError.videoFileNotFound
        }
        if mode.requiresIOS26 {
            guard #available(iOS 26.0, *) else {
                throw LocalSubtitleTranscriptionError.requiresIOS26
            }
        }
        if mode.requiresSenseVoiceModel {
            let isReady = await MainActor.run {
                SenseVoiceModelManager.shared.installedFiles != nil
            }
            guard isReady else {
                throw LocalSubtitleTranscriptionError.senseVoiceModelNotInstalled
            }
        }
        let qwenAPIKey: String?
        if mode.requiresQwenAPI {
            qwenAPIKey = await MainActor.run {
                QwenAPIKeyStore.shared.apiKey
            }
            guard qwenAPIKey?.isEmpty == false else {
                throw LocalSubtitleTranscriptionError.qwenAPIKeyMissing
            }
        } else {
            qwenAPIKey = nil
        }

        try Task.checkCancellation()
        progress?(SubtitleTranscriptionProgress(
            phase: .extractingAudio,
            fractionCompleted: 0.03
        ))
        let extractedAudio = try await SubtitleAudioExtractor.shared.extractAudio(
            from: videoURL
        )
        defer { try? FileManager.default.removeItem(at: extractedAudio.url) }
        progress?(SubtitleTranscriptionProgress(
            phase: .extractingAudio,
            fractionCompleted: 0.09
        ))

        switch mode {
        case .apple:
            let candidate = try await runApple(
                extractedAudio: extractedAudio,
                language: language,
                referenceText: referenceText,
                progressRange: 0.1...0.99,
                progress: progress
            )
            progress?(SubtitleTranscriptionProgress(
                phase: .completed,
                fractionCompleted: 1
            ))
            return SubtitleTranscriptionBatchResult(
                candidates: [candidate],
                selectedProvider: .apple
            )

        case .senseVoice:
            let candidate = try await runSenseVoice(
                extractedAudio: extractedAudio,
                progressRange: 0.1...0.99,
                progress: progress
            )
            progress?(SubtitleTranscriptionProgress(
                phase: .completed,
                fractionCompleted: 1
            ))
            return SubtitleTranscriptionBatchResult(
                candidates: [candidate],
                selectedProvider: .senseVoice
            )

        case .qwen:
            guard let qwenAPIKey else {
                throw LocalSubtitleTranscriptionError.qwenAPIKeyMissing
            }
            let candidate = try await runQwen(
                extractedAudio: extractedAudio,
                apiKey: qwenAPIKey,
                progressRange: 0.1...0.99,
                progress: progress
            )
            progress?(SubtitleTranscriptionProgress(
                phase: .completed,
                fractionCompleted: 1
            ))
            return SubtitleTranscriptionBatchResult(
                candidates: [candidate],
                selectedProvider: .qwen
            )

        case .comparison:
            guard let qwenAPIKey else {
                throw LocalSubtitleTranscriptionError.qwenAPIKeyMissing
            }
            var candidates: [SubtitleRecognitionCandidate] = []
            var failures: [SubtitleRecognitionFailure] = []

            if #available(iOS 26.0, *) {
                do {
                    candidates.append(try await runApple(
                        extractedAudio: extractedAudio,
                        language: .chinese,
                        referenceText: "",
                        progressRange: 0.1...0.38,
                        progress: progress
                    ))
                } catch {
                    failures.append(try recognitionFailure(for: .apple, error: error))
                }
                try Task.checkCancellation()
                do {
                    candidates.append(try await runSenseVoice(
                        extractedAudio: extractedAudio,
                        progressRange: 0.4...0.68,
                        progress: progress
                    ))
                } catch {
                    failures.append(try recognitionFailure(for: .senseVoice, error: error))
                }
                try Task.checkCancellation()
                do {
                    candidates.append(try await runQwen(
                        extractedAudio: extractedAudio,
                        apiKey: qwenAPIKey,
                        progressRange: 0.7...0.99,
                        progress: progress
                    ))
                } catch {
                    failures.append(try recognitionFailure(for: .qwen, error: error))
                }
            } else {
                do {
                    candidates.append(try await runSenseVoice(
                        extractedAudio: extractedAudio,
                        progressRange: 0.1...0.53,
                        progress: progress
                    ))
                } catch {
                    failures.append(try recognitionFailure(for: .senseVoice, error: error))
                }
                try Task.checkCancellation()
                do {
                    candidates.append(try await runQwen(
                        extractedAudio: extractedAudio,
                        apiKey: qwenAPIKey,
                        progressRange: 0.55...0.99,
                        progress: progress
                    ))
                } catch {
                    failures.append(try recognitionFailure(for: .qwen, error: error))
                }
            }

            guard !candidates.isEmpty else {
                throw LocalSubtitleTranscriptionError.recognitionFailed(
                    failures.map(\.message).joined(separator: " / ")
                )
            }
            progress?(SubtitleTranscriptionProgress(
                phase: .completed,
                fractionCompleted: 1
            ))
            return SubtitleTranscriptionBatchResult(
                candidates: candidates,
                selectedProvider: candidates.contains(where: { $0.provider == .qwen })
                    ? .qwen
                    : candidates[0].provider,
                failures: failures
            )
        }
    }

    private func runApple(
        extractedAudio: ExtractedSubtitleAudio,
        language: SubtitleRecognitionLanguage,
        referenceText: String,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) async throws -> SubtitleRecognitionCandidate {
        guard #available(iOS 26.0, *) else {
            throw LocalSubtitleTranscriptionError.requiresIOS26
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try await LocalSubtitleTranscriber.shared.transcribeAudio(
            at: extractedAudio.url,
            timelineOffset: extractedAudio.timelineOffset,
            language: language,
            referenceText: referenceText,
            progress: mappedProgress(
                to: progressRange,
                target: progress
            )
        )
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        return SubtitleRecognitionCandidate(
            provider: .apple,
            result: result.withRecognitionDuration(duration)
        )
    }

    private func runSenseVoice(
        extractedAudio: ExtractedSubtitleAudio,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) async throws -> SubtitleRecognitionCandidate {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try await SenseVoiceSubtitleTranscriber.shared.transcribeAudio(
            at: extractedAudio.url,
            timelineOffset: extractedAudio.timelineOffset,
            progress: mappedProgress(
                to: progressRange,
                target: progress
            )
        )
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        return SubtitleRecognitionCandidate(
            provider: .senseVoice,
            result: result.withRecognitionDuration(duration)
        )
    }

    private func runQwen(
        extractedAudio: ExtractedSubtitleAudio,
        apiKey: String,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) async throws -> SubtitleRecognitionCandidate {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try await QwenASRSubtitleTranscriber.shared.transcribeAudio(
            at: extractedAudio.url,
            timelineOffset: extractedAudio.timelineOffset,
            apiKey: apiKey,
            progress: mappedProgress(
                to: progressRange,
                target: progress
            )
        )
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        return SubtitleRecognitionCandidate(
            provider: .qwen,
            result: result.withRecognitionDuration(duration)
        )
    }

    private func recognitionFailure(
        for provider: SubtitleRecognitionProvider,
        error: Error
    ) throws -> SubtitleRecognitionFailure {
        if error is CancellationError {
            throw CancellationError()
        }
        return SubtitleRecognitionFailure(
            provider: provider,
            message: error.localizedDescription
        )
    }

    private func mappedProgress(
        to range: ClosedRange<Double>,
        target: ProgressHandler?
    ) -> ProgressHandler {
        { progress in
            let span = range.upperBound - range.lowerBound
            target?(SubtitleTranscriptionProgress(
                phase: progress.phase,
                fractionCompleted: range.lowerBound
                    + progress.fractionCompleted * span
            ))
        }
    }
}

private extension SubtitleTranscriptionResult {
    func withRecognitionDuration(_ duration: TimeInterval) -> SubtitleTranscriptionResult {
        SubtitleTranscriptionResult(
            cues: cues,
            metadata: SubtitleRecognitionMetadata(
                provider: metadata.provider,
                routes: metadata.routes,
                referenceGuidedSelections: metadata.referenceGuidedSelections,
                modelIdentifier: metadata.modelIdentifier,
                recognitionDuration: max(duration, 0)
            )
        )
    }
}
