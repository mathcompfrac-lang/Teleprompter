import AVFoundation
import Foundation
import SherpaOnnx
import SherpaOnnxC

/// 使用 SenseVoice 中文模型与 Silero VAD 生成带时间轴的本地字幕。
final class SenseVoiceSubtitleTranscriber: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SubtitleTranscriptionProgress) -> Void

    static let shared = SenseVoiceSubtitleTranscriber()

    private struct SpeechSegment: Sendable {
        let startSample: Int
        let samples: [Float]
    }

    private struct TimedCharacter {
        let character: Character
        let start: Double
        let end: Double
    }

    private static let sampleRate = 16_000
    private static let vadWindowSize = 512
    private static let maximumCharactersPerCue = 22
    private static let maximumDurationPerCue: TimeInterval = 4.5

    private init() {}

    func transcribeAudio(
        at audioURL: URL,
        timelineOffset: CMTime,
        progress: ProgressHandler? = nil
    ) async throws -> SubtitleTranscriptionResult {
        guard let modelFiles = await MainActor.run(
            body: { SenseVoiceModelManager.shared.installedFiles }
        ) else {
            throw LocalSubtitleTranscriptionError.senseVoiceModelNotInstalled
        }
        let offsetSeconds = timelineOffset.seconds.isFinite ? timelineOffset.seconds : 0

        let transcriptionTask = Task.detached(priority: .userInitiated) {
            try Self.performTranscription(
                audioURL: audioURL,
                modelFiles: modelFiles,
                timelineOffsetSeconds: max(offsetSeconds, 0),
                progress: progress
            )
        }
        return try await withTaskCancellationHandler(operation: {
            try await transcriptionTask.value
        }, onCancel: {
            transcriptionTask.cancel()
        })
    }

    private static func performTranscription(
        audioURL: URL,
        modelFiles: SenseVoiceModelFiles,
        timelineOffsetSeconds: Double,
        progress: ProgressHandler?
    ) throws -> SubtitleTranscriptionResult {
        try Task.checkCancellation()
        progress?(SubtitleTranscriptionProgress(
            phase: .preparingModel,
            fractionCompleted: 0.03
        ))

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelFiles.model.path,
            language: "zh",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: modelFiles.tokens.path,
            numThreads: 1,
            provider: "cpu",
            debug: 0,
            senseVoice: senseVoiceConfig
        )
        let featureConfig = sherpaOnnxFeatureConfig(
            sampleRate: sampleRate,
            featureDim: 80
        )
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featureConfig,
            modelConfig: modelConfig
        )
        let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)

        var cues: [SubtitleCue] = []
        let segmentCount = try processSpeechSegments(
            in: audioURL,
            vadModelURL: modelFiles.vad,
            progress: progress
        ) { segment in
            try Task.checkCancellation()
            let result = recognizer.decode(
                samples: segment.samples,
                sampleRate: sampleRate
            )
            let tokens: [String] = {
                guard let pointers = result.result.pointee.tokens_arr else { return [] }
                return (0..<result.count).compactMap { index in
                    guard let pointer = pointers[index] else { return nil }
                    return String(cString: pointer)
                }
            }()
            let segmentStart = Double(segment.startSample) / Double(sampleRate)
            let segmentEnd = segmentStart
                + Double(segment.samples.count) / Double(sampleRate)
            cues.append(contentsOf: makeCues(
                tokens: tokens,
                fallbackText: result.text,
                timestamps: result.timestamps,
                segmentStart: segmentStart + timelineOffsetSeconds,
                segmentEnd: segmentEnd + timelineOffsetSeconds
            ))
        }
        guard segmentCount > 0 else {
            throw LocalSubtitleTranscriptionError.emptyTranscript
        }

        let validCues = cues
            .filter(\.isValid)
            .sorted { CMTimeCompare($0.startTime, $1.startTime) < 0 }
        guard !validCues.isEmpty else {
            throw LocalSubtitleTranscriptionError.emptyTranscript
        }

        progress?(SubtitleTranscriptionProgress(
            phase: .completed,
            fractionCompleted: 1
        ))
        return SubtitleTranscriptionResult(
            cues: validCues,
            metadata: SubtitleRecognitionMetadata(
                provider: .senseVoice,
                modelIdentifier: SenseVoiceModelManager.modelIdentifier
            )
        )
    }

    private static func processSpeechSegments(
        in audioURL: URL,
        vadModelURL: URL,
        progress: ProgressHandler?,
        onSegment: (SpeechSegment) throws -> Void
    ) throws -> Int {
        let sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: vadModelURL.path,
            threshold: 0.25,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.5,
            windowSize: vadWindowSize,
            maxSpeechDuration: 10
        )
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: Int32(sampleRate),
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig,
            buffer_size_in_seconds: 30
        )

        var segmentCount = 0
        var pendingSamples: [Float] = []
        pendingSamples.reserveCapacity(vadWindowSize * 2)

        func drainSegments() throws {
            while !vad.isEmpty() {
                let segment = vad.front()
                vad.pop()
                if segment.n > 0, !segment.samples.isEmpty {
                    try onSegment(SpeechSegment(
                        startSample: Int(segment.start),
                        samples: segment.samples
                    ))
                    segmentCount += 1
                }
            }
        }

        var processedFrames: Int64 = 0
        let sourceDuration = try sourceAudioDuration(at: audioURL)
        try forEachMono16kChunk(in: audioURL) { chunk in
            try Task.checkCancellation()
            pendingSamples.append(contentsOf: chunk)
            var consumed = 0
            while pendingSamples.count - consumed >= vadWindowSize {
                let end = consumed + vadWindowSize
                vad.acceptWaveform(samples: Array(pendingSamples[consumed..<end]))
                consumed = end
                try drainSegments()
            }
            if consumed > 0 {
                pendingSamples.removeFirst(consumed)
            }
            processedFrames += Int64(chunk.count)
            let processedSeconds = Double(processedFrames) / Double(sampleRate)
            let fraction = sourceDuration > 0
                ? min(processedSeconds / sourceDuration, 1)
                : 0
            progress?(SubtitleTranscriptionProgress(
                phase: .transcribing,
                fractionCompleted: 0.08 + fraction * 0.9
            ))
        }

        if !pendingSamples.isEmpty {
            pendingSamples.append(
                contentsOf: repeatElement(
                    0,
                    count: vadWindowSize - pendingSamples.count
                )
            )
            vad.acceptWaveform(samples: pendingSamples)
            try drainSegments()
        }
        vad.flush()
        try drainSegments()
        progress?(SubtitleTranscriptionProgress(
            phase: .transcribing,
            fractionCompleted: 0.98
        ))
        return segmentCount
    }

    private static func sourceAudioDuration(at audioURL: URL) throws -> Double {
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let sampleRate = file.processingFormat.sampleRate
            return sampleRate > 0 ? Double(file.length) / sampleRate : 0
        } catch {
            throw LocalSubtitleTranscriptionError.audioLoadFailed(
                error.localizedDescription
            )
        }
    }

    private static func forEachMono16kChunk(
        in audioURL: URL,
        body: ([Float]) throws -> Void
    ) throws {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw LocalSubtitleTranscriptionError.audioLoadFailed(
                error.localizedDescription
            )
        }

        let inputFormat = audioFile.processingFormat
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: 8_192
              ) else {
            throw LocalSubtitleTranscriptionError.audioLoadFailed(
                "Could not create a 16 kHz mono audio converter."
            )
        }

        while audioFile.framePosition < audioFile.length {
            try Task.checkCancellation()
            let remaining = audioFile.length - audioFile.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(inputBuffer.frameCapacity), remaining))
            try audioFile.read(into: inputBuffer, frameCount: frameCount)
            guard inputBuffer.frameLength > 0 else { break }

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(
                ceil(Double(inputBuffer.frameLength) * ratio) + 32
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw LocalSubtitleTranscriptionError.audioLoadFailed(
                    "Could not allocate an audio conversion buffer."
                )
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw LocalSubtitleTranscriptionError.audioLoadFailed(
                    conversionError?.localizedDescription
                        ?? "Audio conversion failed."
                )
            }
            try emitSamples(from: outputBuffer, body: body)
        }

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 8_192
            ) else { break }
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                throw LocalSubtitleTranscriptionError.audioLoadFailed(
                    conversionError?.localizedDescription
                        ?? "Audio conversion failed."
                )
            }
            try emitSamples(from: outputBuffer, body: body)
            if status == .endOfStream || outputBuffer.frameLength == 0 {
                break
            }
        }
    }

    private static func emitSamples(
        from buffer: AVAudioPCMBuffer,
        body: ([Float]) throws -> Void
    ) throws {
        guard buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            )
        )
        try body(samples)
    }

    private static func makeCues(
        tokens: [String],
        fallbackText rawText: String,
        timestamps: [Float],
        segmentStart: Double,
        segmentEnd: Double
    ) -> [SubtitleCue] {
        let text = cleanRecognizedText(rawText)
        guard !text.isEmpty, segmentEnd > segmentStart else { return [] }
        let tokenText = cleanRecognizedText(tokens.map(cleanRecognizedToken).joined())
        guard tokens.count == timestamps.count,
              !timestamps.isEmpty,
              tokenText == text else {
            return makeProportionalCues(
                text: text,
                segmentStart: segmentStart,
                segmentEnd: segmentEnd
            )
        }

        var timedCharacters: [TimedCharacter] = []
        for index in tokens.indices {
            let tokenText = cleanRecognizedToken(tokens[index])
            let tokenCharacters = Array(tokenText)
            guard !tokenCharacters.isEmpty else { continue }
            let relativeStart = max(Double(timestamps[index]), 0)
            let nextRelativeStart = index + 1 < timestamps.count
                ? max(Double(timestamps[index + 1]), relativeStart + 0.04)
                : segmentEnd - segmentStart
            let tokenStart = min(
                max(segmentStart + relativeStart, segmentStart),
                segmentEnd - 0.04
            )
            let tokenEnd = min(
                segmentEnd,
                segmentStart + max(nextRelativeStart, relativeStart + 0.08)
            )
            for characterIndex in tokenCharacters.indices {
                let startFraction = Double(characterIndex) / Double(tokenCharacters.count)
                let endFraction = Double(characterIndex + 1) / Double(tokenCharacters.count)
                timedCharacters.append(TimedCharacter(
                    character: tokenCharacters[characterIndex],
                    start: tokenStart + (tokenEnd - tokenStart) * startFraction,
                    end: tokenStart + (tokenEnd - tokenStart) * endFraction
                ))
            }
        }
        guard !timedCharacters.isEmpty else {
            return makeProportionalCues(
                text: text,
                segmentStart: segmentStart,
                segmentEnd: segmentEnd
            )
        }

        var cues: [SubtitleCue] = []
        var currentText = ""
        var cueStart = segmentStart
        var cueEnd = segmentStart

        func flush() {
            let normalized = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedEnd = min(segmentEnd, max(cueEnd, cueStart + 0.08))
            if let cue = SubtitleCue(
                startSeconds: max(cueStart, 0),
                endSeconds: boundedEnd,
                text: normalized
            ), !normalized.isEmpty {
                cues.append(cue)
            }
            currentText = ""
        }

        for timedCharacter in timedCharacters {
            if currentText.isEmpty {
                cueStart = timedCharacter.start
            }
            currentText.append(timedCharacter.character)
            cueEnd = max(timedCharacter.end, timedCharacter.start + 0.08)

            let endsSentence = "。！？!?；;".contains(timedCharacter.character)
            if endsSentence
                || currentText.count >= maximumCharactersPerCue
                || cueEnd - cueStart >= maximumDurationPerCue {
                flush()
            }
        }
        flush()
        return cues
    }

    private static func makeProportionalCues(
        text: String,
        segmentStart: Double,
        segmentEnd: Double
    ) -> [SubtitleCue] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var cues: [SubtitleCue] = []
        var index = 0
        while index < characters.count {
            let endIndex = min(index + maximumCharactersPerCue, characters.count)
            let startFraction = Double(index) / Double(characters.count)
            let endFraction = Double(endIndex) / Double(characters.count)
            let cueStart = segmentStart + (segmentEnd - segmentStart) * startFraction
            let cueEnd = segmentStart + (segmentEnd - segmentStart) * endFraction
            let cueText = String(characters[index..<endIndex])
            if let cue = SubtitleCue(
                startSeconds: cueStart,
                endSeconds: max(cueEnd, cueStart + 0.08),
                text: cueText
            ) {
                cues.append(cue)
            }
            index = endIndex
        }
        return cues
    }

    private static func cleanRecognizedText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: "<\\|[^|]+\\|>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanRecognizedToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(
                of: "<\\|[^|]+\\|>|<[^>]+>",
                with: "",
                options: .regularExpression
            )
    }
}
