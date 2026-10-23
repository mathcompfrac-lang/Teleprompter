import AVFoundation
import Foundation
import Speech

/// 使用系统端侧模型，把视频音轨转换为可校对、可渲染的时间轴字幕。
final class LocalSubtitleTranscriber: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SubtitleTranscriptionProgress) -> Void

    @available(iOS 26.0, *)
    private enum ConfiguredTranscriber {
        case speech(Speech.SpeechTranscriber, SubtitleRecognitionRoute)
        case dictation(Speech.DictationTranscriber, SubtitleRecognitionRoute)

        var route: SubtitleRecognitionRoute {
            switch self {
            case .speech(_, let route), .dictation(_, let route):
                return route
            }
        }
    }

    private struct ExtractedAudio {
        let url: URL
        let timelineOffset: CMTime
    }

    private struct RecognizedCue: Sendable {
        var cue: SubtitleCue
        let confidence: Double?
        let referenceScore: Double
        let localeIdentifier: String
    }

    private struct RecognitionPassResult: Sendable {
        let cues: [RecognizedCue]
        let route: SubtitleRecognitionRoute
        let referenceGuidedSelections: Int
    }

    private struct CandidateSelection {
        let attributedText: AttributedString
        let referenceScore: Double
        let wasReferenceGuided: Bool
    }

    private struct ReferenceMatch {
        let score: Double
        let endIndex: Int
    }

    private struct ReferenceMatcher {
        private let referenceTokens: [String]
        private var cursor = 0

        init(referenceText: String) {
            referenceTokens = LocalSubtitleTranscriber.recognitionTokens(in: referenceText)
        }

        mutating func selectCandidate(
            from candidateTexts: [String],
            allowedAlternativeIndices: Set<Int>
        ) -> (index: Int, score: Double) {
            guard !candidateTexts.isEmpty, !referenceTokens.isEmpty else {
                return (0, 0)
            }

            let matches = candidateTexts.map { match(text: $0) }
            let topMatch = matches[0]
            var selectedIndex = 0
            var selectedMatch = topMatch

            for index in matches.indices.dropFirst()
                where allowedAlternativeIndices.contains(index) {
                let match = matches[index]
                guard match.score >= 0.66,
                      match.score >= topMatch.score + 0.12,
                      match.score > selectedMatch.score else { continue }
                selectedIndex = index
                selectedMatch = match
            }

            let selectedTokenCount = LocalSubtitleTranscriber.recognitionTokens(
                in: candidateTexts[selectedIndex]
            ).count
            if selectedTokenCount >= 2, selectedMatch.score >= 0.5 {
                cursor = max(cursor, selectedMatch.endIndex)
            }
            return (selectedIndex, selectedMatch.score)
        }

        private func match(text: String) -> ReferenceMatch {
            let candidateTokens = LocalSubtitleTranscriber.recognitionTokens(in: text)
            guard !candidateTokens.isEmpty, cursor < referenceTokens.count else {
                return ReferenceMatch(score: 0, endIndex: cursor)
            }

            let searchEnd = min(
                referenceTokens.count,
                cursor + max(48, candidateTokens.count * 4)
            )
            var best = ReferenceMatch(score: 0, endIndex: cursor)

            for start in cursor..<searchEnd {
                let windowEnd = min(
                    searchEnd,
                    start + candidateTokens.count + 4
                )
                guard windowEnd > start else { continue }
                let referenceWindow = Array(referenceTokens[start..<windowEnd])
                let sequenceMatch = LocalSubtitleTranscriber.longestCommonSubsequenceMatch(
                    candidateTokens,
                    referenceWindow
                )
                let matchedCount = sequenceMatch.length
                let coverage = Double(matchedCount) / Double(candidateTokens.count)
                let compactness = Double(matchedCount) / Double(referenceWindow.count)
                let skipPenalty = min(Double(start - cursor) * 0.005, 0.12)
                let score = max(0, coverage * 0.88 + compactness * 0.12 - skipPenalty)
                if score > best.score {
                    best = ReferenceMatch(
                        score: score,
                        endIndex: sequenceMatch.lastReferenceIndex.map {
                            start + $0 + 1
                        } ?? cursor
                    )
                }
            }
            return best
        }
    }

    static let shared = LocalSubtitleTranscriber()

    private let maximumCharactersPerCue = 22
    private let maximumDurationPerCue: TimeInterval = 4.5
    private let minimumSentenceDuration: TimeInterval = 0.8
    private let maximumSilenceWithinCue: TimeInterval = 0.7

    private init() {}

    /// 从本地视频识别字幕。中英混合模式会顺序识别两遍，再按时间轴保守融合。
    /// 参考文稿只用于选择系统已经返回的候选，不会直接补写到识别结果。
    func transcribeVideo(
        at videoURL: URL,
        language: SubtitleRecognitionLanguage = .chinese,
        referenceText: String = "",
        progress: ProgressHandler? = nil
    ) async throws -> SubtitleTranscriptionResult {
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
            language: language,
            referenceText: referenceText,
            progress: progress
        )
    }

    @available(iOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(
        videoURL: URL,
        language: SubtitleRecognitionLanguage,
        referenceText: String,
        progress: ProgressHandler?
    ) async throws -> SubtitleTranscriptionResult {
        try Task.checkCancellation()
        progress?(SubtitleTranscriptionProgress(
            phase: .extractingAudio,
            fractionCompleted: 0.05
        ))

        let extractedAudio = try await extractAudio(from: videoURL)
        defer { try? FileManager.default.removeItem(at: extractedAudio.url) }

        let localeIdentifiers = language.localeIdentifiers
        let passSpan = 0.85 / Double(max(localeIdentifiers.count, 1))
        var passResults: [RecognitionPassResult] = []

        for (index, localeIdentifier) in localeIdentifiers.enumerated() {
            try Task.checkCancellation()
            let passStart = 0.1 + Double(index) * passSpan
            let preparationEnd = passStart + min(0.1, passSpan * 0.2)
            let passEnd = passStart + passSpan

            progress?(SubtitleTranscriptionProgress(
                phase: .preparingModel,
                fractionCompleted: passStart
            ))
            let configuredTranscriber = try await prepareTranscriber(
                requestedLocale: Locale(identifier: localeIdentifier),
                progressRange: passStart...preparationEnd,
                progress: progress
            )

            let passResult = try await recognize(
                extractedAudioURL: extractedAudio.url,
                configuredTranscriber: configuredTranscriber,
                referenceText: referenceText,
                progressRange: preparationEnd...passEnd,
                progress: progress
            )
            passResults.append(passResult)
        }

        let relativeCues: [SubtitleCue]
        if language == .bilingual, passResults.count == 2 {
            relativeCues = mergeBilingualCues(
                chinese: passResults[0].cues,
                english: passResults[1].cues
            )
        } else {
            relativeCues = passResults.first?.cues.map(\.cue) ?? []
        }

        let cues = offsetCues(relativeCues, by: extractedAudio.timelineOffset)
        guard !cues.isEmpty else {
            throw LocalSubtitleTranscriptionError.emptyTranscript
        }

        progress?(SubtitleTranscriptionProgress(
            phase: .completed,
            fractionCompleted: 1
        ))
        return SubtitleTranscriptionResult(
            cues: cues,
            metadata: SubtitleRecognitionMetadata(
                routes: passResults.map(\.route),
                referenceGuidedSelections: passResults.reduce(0) {
                    $0 + $1.referenceGuidedSelections
                }
            )
        )
    }

    @available(iOS 26.0, *)
    private func recognize(
        extractedAudioURL: URL,
        configuredTranscriber: ConfiguredTranscriber,
        referenceText: String,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) async throws -> RecognitionPassResult {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: extractedAudioURL)
        } catch {
            throw LocalSubtitleTranscriptionError.audioLoadFailed(error.localizedDescription)
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        let audioDuration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
        guard audioFile.length > 0, audioDuration > 0 else {
            throw LocalSubtitleTranscriptionError.emptyAudio
        }

        progress?(SubtitleTranscriptionProgress(
            phase: .transcribing,
            fractionCompleted: progressRange.lowerBound
        ))

        let analyzer: SpeechAnalyzer
        let resultTask: Task<(cues: [RecognizedCue], selections: Int), Error>
        let route = configuredTranscriber.route

        switch configuredTranscriber {
        case .speech(let transcriber, _):
            analyzer = SpeechAnalyzer(modules: [transcriber])
            resultTask = Task {
                try await self.collectCues(
                    from: transcriber,
                    localeIdentifier: route.localeIdentifier,
                    referenceText: referenceText,
                    audioDuration: audioDuration,
                    progressRange: progressRange,
                    progress: progress
                )
            }
        case .dictation(let transcriber, _):
            analyzer = SpeechAnalyzer(modules: [transcriber])
            resultTask = Task {
                try await self.collectCues(
                    from: transcriber,
                    localeIdentifier: route.localeIdentifier,
                    referenceText: referenceText,
                    audioDuration: audioDuration,
                    progressRange: progressRange,
                    progress: progress
                )
            }
        }

        return try await withTaskCancellationHandler(operation: {
            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    throw LocalSubtitleTranscriptionError.emptyAudio
                }

                let collected = try await resultTask.value
                try Task.checkCancellation()
                return RecognitionPassResult(
                    cues: collected.cues,
                    route: route,
                    referenceGuidedSelections: collected.selections
                )
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
        progressRange: ClosedRange<Double>,
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
                reportingOptions: [.alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
            try await installAssetsIfNeeded(
                supporting: [transcriber],
                progressRange: progressRange,
                progress: progress
            )
            return .speech(
                transcriber,
                SubtitleRecognitionRoute(
                    engine: .speechTranscriber,
                    localeIdentifier: locale.identifier
                )
            )
        }

        // SpeechTranscriber 对部分旧硬件不可用；DictationTranscriber 使用兼容
        // SFSpeechRecognizer 的端侧模型，但 long-dictation preset 没有一分钟限制。
        if let locale = await Speech.DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) {
            let preset = Speech.DictationTranscriber.Preset.timeIndexedLongDictation
            let transcriber = Speech.DictationTranscriber(
                locale: locale,
                contentHints: preset.contentHints,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
                attributeOptions: preset.attributeOptions.union([.transcriptionConfidence])
            )
            try await installAssetsIfNeeded(
                supporting: [transcriber],
                progressRange: progressRange,
                progress: progress
            )
            return .dictation(
                transcriber,
                SubtitleRecognitionRoute(
                    engine: .dictationTranscriber,
                    localeIdentifier: locale.identifier
                )
            )
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
        progressRange: ClosedRange<Double>,
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
                        let mappedFraction = progressRange.lowerBound
                            + (progressRange.upperBound - progressRange.lowerBound) * fraction
                        progress?(SubtitleTranscriptionProgress(
                            phase: .preparingModel,
                            fractionCompleted: mappedFraction
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
                    fractionCompleted: progressRange.upperBound
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
        localeIdentifier: String,
        referenceText: String,
        audioDuration: TimeInterval,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) async throws -> (cues: [RecognizedCue], selections: Int) {
        var cues: [RecognizedCue] = []
        var matcher = ReferenceMatcher(referenceText: referenceText)
        var guidedSelections = 0

        for try await result in transcriber.results {
            try Task.checkCancellation()
            let selection = selectCandidate(
                primary: result.text,
                alternatives: result.alternatives,
                matcher: &matcher
            )
            if selection.wasReferenceGuided {
                guidedSelections += 1
            }
            appendCues(
                from: selection,
                localeIdentifier: localeIdentifier,
                to: &cues,
                audioDuration: audioDuration,
                progressRange: progressRange,
                progress: progress
            )
        }

        return (normalized(cues), guidedSelections)
    }

    @available(iOS 26.0, *)
    private func collectCues(
        from transcriber: Speech.DictationTranscriber,
        localeIdentifier: String,
        referenceText: String,
        audioDuration: TimeInterval,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) async throws -> (cues: [RecognizedCue], selections: Int) {
        var cues: [RecognizedCue] = []
        var matcher = ReferenceMatcher(referenceText: referenceText)
        var guidedSelections = 0

        for try await result in transcriber.results {
            try Task.checkCancellation()
            let selection = selectCandidate(
                primary: result.text,
                alternatives: result.alternatives,
                matcher: &matcher
            )
            if selection.wasReferenceGuided {
                guidedSelections += 1
            }
            appendCues(
                from: selection,
                localeIdentifier: localeIdentifier,
                to: &cues,
                audioDuration: audioDuration,
                progressRange: progressRange,
                progress: progress
            )
        }

        return (normalized(cues), guidedSelections)
    }

    @available(iOS 26.0, *)
    private func selectCandidate(
        primary: AttributedString,
        alternatives: [AttributedString],
        matcher: inout ReferenceMatcher
    ) -> CandidateSelection {
        var candidates: [AttributedString] = []
        var candidateTexts: [String] = []

        for candidate in [primary] + alternatives {
            let text = String(candidate.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !candidateTexts.contains(text) else { continue }
            candidates.append(candidate)
            candidateTexts.append(text)
            if candidates.count == 3 {
                break
            }
        }

        guard candidates.first != nil else {
            return CandidateSelection(
                attributedText: primary,
                referenceScore: 0,
                wasReferenceGuided: false
            )
        }
        let topConfidence = meanTranscriptionConfidence(in: candidates[0])
        var allowedAlternativeIndices: Set<Int> = []
        for index in candidates.indices.dropFirst() {
            guard let confidence = meanTranscriptionConfidence(in: candidates[index]) else {
                continue
            }
            if let topConfidence {
                if confidence >= 0.35, confidence >= topConfidence - 0.03 {
                    allowedAlternativeIndices.insert(index)
                }
            } else if confidence >= 0.55 {
                allowedAlternativeIndices.insert(index)
            }
        }

        let match = matcher.selectCandidate(
            from: candidateTexts,
            allowedAlternativeIndices: allowedAlternativeIndices
        )
        let selectedIndex = min(max(match.index, 0), candidates.count - 1)
        return CandidateSelection(
            attributedText: candidates[selectedIndex],
            referenceScore: match.score,
            wasReferenceGuided: selectedIndex > 0
        )
    }

    @available(iOS 26.0, *)
    private func meanTranscriptionConfidence(in text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0
        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                total += Double(confidence)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    @available(iOS 26.0, *)
    private func appendCues(
        from selection: CandidateSelection,
        localeIdentifier: String,
        to cues: inout [RecognizedCue],
        audioDuration: TimeInterval,
        progressRange: ClosedRange<Double>,
        progress: ProgressHandler?
    ) {
        let newCues = makeCues(
            from: selection.attributedText,
            localeIdentifier: localeIdentifier,
            referenceScore: selection.referenceScore
        )
        cues.append(contentsOf: newCues)

        if let lastCue = newCues.last {
            let recognitionFraction = min(
                max(lastCue.cue.endSeconds / audioDuration, 0),
                1
            )
            let mappedFraction = progressRange.lowerBound
                + (progressRange.upperBound - progressRange.lowerBound) * recognitionFraction
            progress?(SubtitleTranscriptionProgress(
                phase: .transcribing,
                fractionCompleted: mappedFraction
            ))
        }
    }

    private func normalized(_ cues: [RecognizedCue]) -> [RecognizedCue] {
        cues
            .filter { $0.cue.isValid }
            .sorted { lhs, rhs in
                CMTimeCompare(lhs.cue.startTime, rhs.cue.startTime) < 0
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
    private func makeCues(
        from attributedText: AttributedString,
        localeIdentifier: String,
        referenceScore: Double
    ) -> [RecognizedCue] {
        var cues: [RecognizedCue] = []
        var currentText = ""
        var currentStart: CMTime?
        var currentEnd: CMTime?
        var previousTimedEnd: CMTime?
        var pendingUntimedText = ""
        var confidenceTotal = 0.0
        var confidenceCount = 0

        func flushCurrentCue() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = currentStart,
               let end = currentEnd,
               !text.isEmpty,
               CMTimeCompare(end, start) > 0 {
                cues.append(RecognizedCue(
                    cue: SubtitleCue(
                        timeRange: CMTimeRange(start: start, end: end),
                        text: text
                    ),
                    confidence: confidenceCount > 0
                        ? confidenceTotal / Double(confidenceCount)
                        : nil,
                    referenceScore: referenceScore,
                    localeIdentifier: localeIdentifier
                ))
            }
            currentText = ""
            currentStart = nil
            currentEnd = nil
            confidenceTotal = 0
            confidenceCount = 0
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
                    cues[cues.count - 1].cue.text.append(rawText)
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

            // 在系统已经给出独立时间片时，把中英文脚本切换处分句。这样混合
            // 模式可以只替换英文时间片，不会为了修正一个词而覆盖整句中文。
            if currentStart != nil,
               shouldSplitAtScriptTransition(currentText, rawText) {
                flushCurrentCue()
            }

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
            if let confidence = run.transcriptionConfidence {
                confidenceTotal += Double(confidence)
                confidenceCount += 1
            }

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
            appendRecognizedText(pendingUntimedText, to: &cues[cues.count - 1].cue.text)
        }
        return cues
    }

    private func mergeBilingualCues(
        chinese: [RecognizedCue],
        english: [RecognizedCue]
    ) -> [SubtitleCue] {
        if chinese.isEmpty {
            return normalized(english).map(\.cue)
        }

        var merged: [RecognizedCue] = []
        var usedEnglishIdentifiers: Set<UUID> = []

        for chineseCue in chinese {
            let candidates = english
                .filter {
                    !usedEnglishIdentifiers.contains($0.cue.id)
                        && mutualOverlapCoverage(
                            chineseCue.cue.timeRange,
                            $0.cue.timeRange
                        ) >= 0.6
                }
                .sorted {
                    mutualOverlapCoverage(chineseCue.cue.timeRange, $0.cue.timeRange)
                        > mutualOverlapCoverage(chineseCue.cue.timeRange, $1.cue.timeRange)
                }

            if let englishCue = candidates.first,
               shouldPreferEnglish(englishCue, over: chineseCue) {
                merged.append(RecognizedCue(
                    cue: SubtitleCue(
                        id: chineseCue.cue.id,
                        timeRange: chineseCue.cue.timeRange,
                        text: englishCue.cue.text
                    ),
                    confidence: englishCue.confidence,
                    referenceScore: englishCue.referenceScore,
                    localeIdentifier: englishCue.localeIdentifier
                ))
                usedEnglishIdentifiers.insert(englishCue.cue.id)
            } else {
                merged.append(chineseCue)
            }
        }

        return normalized(merged).map(\.cue)
    }

    private func shouldPreferEnglish(
        _ english: RecognizedCue,
        over chinese: RecognizedCue
    ) -> Bool {
        guard containsLatinLetter(english.cue.text) else { return false }
        let chineseContainsHan = containsHanCharacter(chinese.cue.text)
        let chineseContainsLatin = containsLatinLetter(chinese.cue.text)
        guard !(chineseContainsHan && chineseContainsLatin) else { return false }

        if english.referenceScore >= 0.66,
           english.referenceScore >= chinese.referenceScore + 0.08 {
            guard let englishConfidence = english.confidence else { return false }
            if let chineseConfidence = chinese.confidence {
                return englishConfidence >= chineseConfidence
            }
            return englishConfidence >= 0.5
        }

        if chineseContainsHan {
            guard let englishConfidence = english.confidence,
                  let chineseConfidence = chinese.confidence else { return false }
            return englishConfidence >= 0.72
                && englishConfidence >= chineseConfidence + 0.18
        }

        guard chineseContainsLatin else { return false }

        switch (english.confidence, chinese.confidence) {
        case let (englishConfidence?, chineseConfidence?):
            return englishConfidence >= 0.5
                && englishConfidence >= chineseConfidence + 0.1
        default:
            return false
        }
    }

    private func mutualOverlapCoverage(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Double {
        let start = max(lhs.start.seconds, rhs.start.seconds)
        let end = min(CMTimeRangeGetEnd(lhs).seconds, CMTimeRangeGetEnd(rhs).seconds)
        let intersection = max(0, end - start)
        let lhsDuration = lhs.duration.seconds
        let rhsDuration = rhs.duration.seconds
        guard intersection.isFinite,
              lhsDuration.isFinite,
              rhsDuration.isFinite,
              lhsDuration > 0,
              rhsDuration > 0 else { return 0 }
        return min(
            max(min(intersection / lhsDuration, intersection / rhsDuration), 0),
            1
        )
    }

    private func shouldSplitAtScriptTransition(_ currentText: String, _ fragment: String) -> Bool {
        let currentContainsHan = containsHanCharacter(currentText)
        let currentContainsLatin = containsLatinLetter(currentText)
        let fragmentContainsHan = containsHanCharacter(fragment)
        let fragmentContainsLatin = containsLatinLetter(fragment)
        return (currentContainsHan && fragmentContainsLatin)
            || (currentContainsLatin && fragmentContainsHan)
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

    private func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (65...90).contains(Int($0.value)) || (97...122).contains(Int($0.value))
        }
    }

    private func containsHanCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func recognitionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var asciiWord = ""

        func flushASCIIWord() {
            guard !asciiWord.isEmpty else { return }
            tokens.append(asciiWord.lowercased())
            asciiWord = ""
        }

        for character in text {
            if let asciiValue = character.asciiValue,
               (48...57).contains(asciiValue)
                    || (65...90).contains(asciiValue)
                    || (97...122).contains(asciiValue) {
                asciiWord.append(character)
                continue
            }

            flushASCIIWord()
            if character.isLetter || character.isNumber {
                tokens.append(String(character).lowercased())
            }
        }
        flushASCIIWord()
        return tokens
    }

    private static func longestCommonSubsequenceMatch(
        _ lhs: [String],
        _ rhs: [String]
    ) -> (length: Int, lastReferenceIndex: Int?) {
        guard !lhs.isEmpty, !rhs.isEmpty else { return (0, nil) }
        var table = Array(
            repeating: Array(repeating: 0, count: rhs.count + 1),
            count: lhs.count + 1
        )

        for leftIndex in lhs.indices {
            for rightIndex in rhs.indices {
                if lhs[leftIndex] == rhs[rightIndex] {
                    table[leftIndex + 1][rightIndex + 1] = table[leftIndex][rightIndex] + 1
                } else {
                    table[leftIndex + 1][rightIndex + 1] = max(
                        table[leftIndex][rightIndex + 1],
                        table[leftIndex + 1][rightIndex]
                    )
                }
            }
        }

        var leftIndex = lhs.count
        var rightIndex = rhs.count
        var lastReferenceIndex: Int?
        while leftIndex > 0, rightIndex > 0 {
            if lhs[leftIndex - 1] == rhs[rightIndex - 1] {
                if lastReferenceIndex == nil {
                    lastReferenceIndex = rightIndex - 1
                }
                leftIndex -= 1
                rightIndex -= 1
            } else if table[leftIndex - 1][rightIndex] >= table[leftIndex][rightIndex - 1] {
                leftIndex -= 1
            } else {
                rightIndex -= 1
            }
        }

        return (table[lhs.count][rhs.count], lastReferenceIndex)
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
            // 原音轨插入独立音频的 0 秒，识别完成后再统一加回原始起点。
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
