import AVFoundation
import Foundation
import Speech

/// 使用系统端侧模型，把视频音轨转换为可直接用于硬字幕渲染的时间轴。
final class LocalSubtitleTranscriber: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SubtitleTranscriptionProgress) -> Void

    @available(iOS 26.0, *)
    private enum ConfiguredTranscriber {
        case speech(Speech.SpeechTranscriber)
        case dictation(Speech.DictationTranscriber)
    }

    private struct ExtractedAudio {
        let url: URL
        let timelineOffset: CMTime
    }

    static let shared = LocalSubtitleTranscriber()

    private let maximumCharactersPerCue = 22
    private let maximumDurationPerCue: TimeInterval = 4.5
    private let minimumSentenceDuration: TimeInterval = 0.8
    private let maximumSilenceWithinCue: TimeInterval = 0.7

    private init() {}

    /// 从本地视频识别字幕。识别结果的时间基准与源视频音轨一致。
    ///
    /// iOS 17 至 iOS 25 不会回退到服务器识别。旧版 `SFSpeechRecognizer`
    /// 对长音频存在一分钟限制，分片还会破坏边界时间精度，因此明确返回不可用。
    func transcribeVideo(
        at videoURL: URL,
        locale requestedLocale: Locale = Locale(identifier: "zh-CN"),
        progress: ProgressHandler? = nil
    ) async throws -> [SubtitleCue] {
        progress?(SubtitleTranscriptionProgress(
            phase: .checkingAvailability,
            fractionCompleted: 0
        ))

        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LocalSubtitleTranscriptionError.videoFileNotFound
        }

        guard #available(iOS 26.0, *) else {
            throw LocalSubtitleTranscriptionError.requiresIOS26
        }

        return try await transcribeWithSpeechAnalyzer(
            videoURL: videoURL,
            requestedLocale: requestedLocale,
            progress: progress
        )
    }

    @available(iOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(
        videoURL: URL,
        requestedLocale: Locale,
        progress: ProgressHandler?
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()

        progress?(SubtitleTranscriptionProgress(
            phase: .preparingModel,
            fractionCompleted: 0.05
        ))

        let configuredTranscriber = try await prepareTranscriber(
            requestedLocale: requestedLocale,
            progress: progress
        )

        try Task.checkCancellation()
        progress?(SubtitleTranscriptionProgress(
            phase: .extractingAudio,
            fractionCompleted: 0.15
        ))

        let extractedAudio = try await extractAudio(from: videoURL)
        defer { try? FileManager.default.removeItem(at: extractedAudio.url) }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: extractedAudio.url)
        } catch {
            throw LocalSubtitleTranscriptionError.audioLoadFailed(
                error.localizedDescription
            )
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        let audioDuration = sampleRate > 0
            ? Double(audioFile.length) / sampleRate
            : 0
        guard audioFile.length > 0, audioDuration > 0 else {
            throw LocalSubtitleTranscriptionError.emptyAudio
        }

        try Task.checkCancellation()
        progress?(SubtitleTranscriptionProgress(
            phase: .transcribing,
            fractionCompleted: 0.2
        ))

        let analyzer: SpeechAnalyzer
        let resultTask: Task<[SubtitleCue], Error>
        switch configuredTranscriber {
        case .speech(let transcriber):
            analyzer = SpeechAnalyzer(modules: [transcriber])
            resultTask = Task<[SubtitleCue], Error> {
                try await self.collectCues(
                    from: transcriber,
                    audioDuration: audioDuration,
                    progress: progress
                )
            }
        case .dictation(let transcriber):
            analyzer = SpeechAnalyzer(modules: [transcriber])
            resultTask = Task<[SubtitleCue], Error> {
                try await self.collectCues(
                    from: transcriber,
                    audioDuration: audioDuration,
                    progress: progress
                )
            }
        }

        return try await withTaskCancellationHandler(operation: {
            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    // analyzeSequence 在调用任务取消时可能提前返回，而不是抛 CancellationError。
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    throw LocalSubtitleTranscriptionError.emptyAudio
                }

                let relativeCues = try await resultTask.value
                try Task.checkCancellation()
                let cues = offsetCues(
                    relativeCues,
                    by: extractedAudio.timelineOffset
                )
                guard !cues.isEmpty else {
                    throw LocalSubtitleTranscriptionError.emptyTranscript
                }

                progress?(SubtitleTranscriptionProgress(
                    phase: .completed,
                    fractionCompleted: 1
                ))
                return cues
            } catch {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await resultTask.value

                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let transcriptionError = error as? LocalSubtitleTranscriptionError {
                    throw transcriptionError
                }
                throw LocalSubtitleTranscriptionError.recognitionFailed(
                    error.localizedDescription
                )
            }
        }, onCancel: {
            resultTask.cancel()
            Task {
                await analyzer.cancelAndFinishNow()
            }
        })
    }

    @available(iOS 26.0, *)
    private func prepareTranscriber(
        requestedLocale: Locale,
        progress: ProgressHandler?
    ) async throws -> ConfiguredTranscriber {
        try Task.checkCancellation()
        if Speech.SpeechTranscriber.isAvailable,
           let locale = await Speech.SpeechTranscriber.supportedLocale(
               equivalentTo: requestedLocale
           ) {
            let transcriber = Speech.SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            try await installAssetsIfNeeded(
                supporting: [transcriber],
                progress: progress
            )
            return .speech(transcriber)
        }

        // SpeechTranscriber 对部分旧硬件不可用；DictationTranscriber 使用兼容
        // SFSpeechRecognizer 的端侧模型，但 long-dictation preset 没有一分钟限制。
        if let locale = await Speech.DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) {
            let transcriber = Speech.DictationTranscriber(
                locale: locale,
                preset: .timeIndexedLongDictation
            )
            try await installAssetsIfNeeded(
                supporting: [transcriber],
                progress: progress
            )
            return .dictation(transcriber)
        }

        if Speech.SpeechTranscriber.isAvailable {
            throw LocalSubtitleTranscriptionError.unsupportedLocale(
                requestedLocale.identifier
            )
        }
        throw LocalSubtitleTranscriptionError.engineUnavailable
    }

    @available(iOS 26.0, *)
    private func installAssetsIfNeeded(
        supporting modules: [any SpeechModule],
        progress: ProgressHandler?
    ) async throws {
        do {
            try Task.checkCancellation()
            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) {
                let progressTask = Task<Void, Never> {
                    while !Task.isCancelled {
                        let rawFraction = installationRequest.progress.fractionCompleted
                        let fraction = rawFraction.isFinite
                            ? min(max(rawFraction, 0), 1)
                            : 0
                        progress?(SubtitleTranscriptionProgress(
                            phase: .preparingModel,
                            fractionCompleted: 0.05 + fraction * 0.09
                        ))
                        if installationRequest.progress.isFinished {
                            return
                        }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                defer { progressTask.cancel() }
                try await installationRequest.downloadAndInstall()
                progress?(SubtitleTranscriptionProgress(
                    phase: .preparingModel,
                    fractionCompleted: 0.14
                ))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalSubtitleTranscriptionError.modelInstallationFailed(
                error.localizedDescription
            )
        }
    }

    @available(iOS 26.0, *)
    private func collectCues(
        from transcriber: Speech.SpeechTranscriber,
        audioDuration: TimeInterval,
        progress: ProgressHandler?
    ) async throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []

        for try await result in transcriber.results {
            try Task.checkCancellation()
            appendCues(
                from: result.text,
                to: &cues,
                audioDuration: audioDuration,
                progress: progress
            )
        }

        return normalized(cues)
    }

    @available(iOS 26.0, *)
    private func collectCues(
        from transcriber: Speech.DictationTranscriber,
        audioDuration: TimeInterval,
        progress: ProgressHandler?
    ) async throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []

        for try await result in transcriber.results {
            try Task.checkCancellation()
            appendCues(
                from: result.text,
                to: &cues,
                audioDuration: audioDuration,
                progress: progress
            )
        }

        return normalized(cues)
    }

    @available(iOS 26.0, *)
    private func appendCues(
        from attributedText: AttributedString,
        to cues: inout [SubtitleCue],
        audioDuration: TimeInterval,
        progress: ProgressHandler?
    ) {
        let newCues = makeCues(from: attributedText)
        cues.append(contentsOf: newCues)

        if let lastCue = newCues.last {
            let recognitionFraction = min(
                max(lastCue.endSeconds / audioDuration, 0),
                1
            )
            progress?(SubtitleTranscriptionProgress(
                phase: .transcribing,
                fractionCompleted: 0.2 + recognitionFraction * 0.75
            ))
        }
    }

    private func normalized(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues
            .filter(\.isValid)
            .sorted { lhs, rhs in
                CMTimeCompare(lhs.startTime, rhs.startTime) < 0
            }
    }

    private func offsetCues(_ cues: [SubtitleCue], by offset: CMTime) -> [SubtitleCue] {
        guard offset.isValid,
              offset.isNumeric,
              CMTimeCompare(offset, .zero) != 0 else {
            return cues
        }

        return cues.map { cue in
            SubtitleCue(
                id: cue.id,
                timeRange: CMTimeRange(
                    start: CMTimeAdd(cue.startTime, offset),
                    duration: cue.timeRange.duration
                ),
                text: cue.text
            )
        }
    }

    @available(iOS 26.0, *)
    private func makeCues(from attributedText: AttributedString) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var currentText = ""
        var currentStart: CMTime?
        var currentEnd: CMTime?
        var previousTimedEnd: CMTime?
        var pendingUntimedText = ""

        func flushCurrentCue() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = currentStart,
               let end = currentEnd,
               !text.isEmpty,
               CMTimeCompare(end, start) > 0 {
                cues.append(SubtitleCue(
                    timeRange: CMTimeRange(start: start, end: end),
                    text: text
                ))
            }
            currentText = ""
            currentStart = nil
            currentEnd = nil
        }

        for run in attributedText.runs {
            let rawText = String(attributedText[run.range].characters)
            guard let timeRange = run.audioTimeRange else {
                if currentStart != nil {
                    currentText.append(rawText)
                    if let start = currentStart,
                       let end = currentEnd,
                       end.seconds - start.seconds >= minimumSentenceDuration,
                       endsSentence(currentText) {
                        flushCurrentCue()
                    }
                } else if rawText.contains(where: { $0.isLetter || $0.isNumber }) {
                    pendingUntimedText.append(rawText)
                } else if !cues.isEmpty {
                    cues[cues.count - 1].text.append(rawText)
                } else {
                    pendingUntimedText.append(rawText)
                }
                continue
            }

            let start = timeRange.start
            let end = CMTimeRangeGetEnd(timeRange)
            guard start.seconds.isFinite,
                  end.seconds.isFinite,
                  CMTimeCompare(end, start) > 0 else {
                continue
            }

            // 超过阈值的静音表示上一句已经结束。先落盘前一句，避免把停顿后
            // 才说出的文字从旧起点提前显示，确保每条字幕贴合实际发声区间。
            if let previousTimedEnd,
               !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let silenceDuration = start.seconds - previousTimedEnd.seconds
                let projectedDuration = currentStart.map {
                    end.seconds - $0.seconds
                } ?? 0
                if (silenceDuration.isFinite
                        && silenceDuration >= maximumSilenceWithinCue)
                    || projectedDuration > maximumDurationPerCue {
                    flushCurrentCue()
                }
            }

            if currentStart == nil {
                currentStart = start
                if !pendingUntimedText.isEmpty {
                    appendRecognizedText(pendingUntimedText, to: &currentText)
                    pendingUntimedText = ""
                }
            }
            currentEnd = end
            previousTimedEnd = end
            appendRecognizedText(rawText, to: &currentText)

            let normalizedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = currentStart.map { end.seconds - $0.seconds } ?? 0
            let reachedLengthLimit = normalizedText.count >= maximumCharactersPerCue
            let reachedDurationLimit = duration >= maximumDurationPerCue
            let reachedSentenceEnd = duration >= minimumSentenceDuration
                && endsSentence(normalizedText)

            if reachedLengthLimit || reachedDurationLimit || reachedSentenceEnd {
                flushCurrentCue()
            }
        }

        flushCurrentCue()
        if !pendingUntimedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !cues.isEmpty {
            appendRecognizedText(pendingUntimedText, to: &cues[cues.count - 1].text)
        }
        return cues
    }

    private func appendRecognizedText(_ fragment: String, to text: inout String) {
        guard !fragment.isEmpty else { return }
        guard let last = text.last,
              let first = fragment.first else {
            text.append(fragment)
            return
        }

        let needsSpace = !last.isWhitespace
            && !first.isWhitespace
            && isASCIIWordCharacter(last)
            && isASCIIWordCharacter(first)
        if needsSpace {
            text.append(" ")
        }
        text.append(fragment)
    }

    private func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard let value = character.asciiValue else { return false }
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？!?；;\n".contains(last)
    }

    @available(iOS 26.0, *)
    private func extractAudio(from videoURL: URL) async throws -> ExtractedAudio {
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
        try? FileManager.default.removeItem(at: destination)

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
            // 明确把原音轨内容插到独立音频文件的 0 秒，识别结果因此是相对
            // 时间；返回前再加回原音轨起点，可确定地还原到视频时间轴。
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
            try await exportSession.export(to: destination, as: .m4a)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw LocalSubtitleTranscriptionError.audioExtractionFailed(
                error.localizedDescription
            )
        }

        return ExtractedAudio(
            url: destination,
            timelineOffset: audioTimeRange.start
        )
    }
}
