@preconcurrency import AVFoundation
import Accelerate
@preconcurrency import CoreML
import Foundation

/// 使用随 App 打包的 Spleeter 2-stem Core ML 模型生成仅含人声的新视频。
///
/// 该实现针对普通立体声视频，保留源视频压缩数据，只重新编码一条人声音轨。
/// 模型资源应以 `Spleeter2StemsVocalMask-F1536-fp16.mlmodelc` 的名称放入主 Bundle。
@MainActor
final class SpleeterForegroundAudioRenderer {

    enum Support: Equatable {
        case available
        case sourceFileMissing
        case modelMissing
        case modelInvalid
        case noAudioTrack

        var localizedDescription: String {
            switch self {
            case .available:
                return String(localized: "支持本地人声分离")
            case .sourceFileMissing:
                return String(localized: "原视频文件不存在")
            case .modelMissing:
                return String(localized: "人声分离模型未包含在 App 中")
            case .modelInvalid:
                return String(localized: "人声分离模型与当前版本不兼容")
            case .noAudioTrack:
                return String(localized: "该视频不包含音轨")
            }
        }
    }

    enum RenderError: LocalizedError {
        case renderAlreadyInProgress
        case sourceFileMissing
        case sourceAndOutputAreSame
        case outputMustBeMovie
        case outputAlreadyExists
        case modelMissing
        case modelInvalid
        case modelLoadFailed(message: String)
        case modelPredictionFailed(message: String)
        case invalidModelOutput
        case noAudioTrack
        case missingVideoTrack
        case invalidDuration
        case cannotCreateReaderOutput
        case cannotCreateWriterInput
        case readerCouldNotStart(message: String)
        case writerCouldNotStart(message: String)
        case readerFailed(message: String)
        case writerFailed(message: String)
        case unsupportedPCMFormat
        case cannotReadAudioSamples
        case cannotCreateAudioFile
        case cannotCreateFFT
        case exportedFileMissing
        case exportedVideoIsInvalid
        case exportedAudioTrackCountInvalid
        case exportedDurationMismatch

        var errorDescription: String? {
            switch self {
            case .renderAlreadyInProgress:
                return String(localized: "已有人声分离视频正在生成")
            case .sourceFileMissing:
                return String(localized: "原视频文件不存在")
            case .sourceAndOutputAreSame:
                return String(localized: "人声版输出路径不能与原视频相同")
            case .outputMustBeMovie:
                return String(localized: "人声版视频必须使用 .mov 文件")
            case .outputAlreadyExists:
                return String(localized: "人声版输出文件已存在，为避免覆盖已停止导出")
            case .modelMissing:
                return Support.modelMissing.localizedDescription
            case .modelInvalid:
                return Support.modelInvalid.localizedDescription
            case let .modelLoadFailed(message):
                return String(localized: "无法加载人声分离模型：\(message)")
            case let .modelPredictionFailed(message):
                return String(localized: "人声分离失败：\(message)")
            case .invalidModelOutput:
                return String(localized: "人声分离模型返回了无效结果")
            case .noAudioTrack:
                return Support.noAudioTrack.localizedDescription
            case .missingVideoTrack:
                return String(localized: "原视频不包含可用的视频轨道")
            case .invalidDuration:
                return String(localized: "无法读取原视频时长")
            case .cannotCreateReaderOutput:
                return String(localized: "当前视频无法创建媒体读取轨道")
            case .cannotCreateWriterInput:
                return String(localized: "当前设备无法创建人声版输出轨道")
            case let .readerCouldNotStart(message):
                return String(localized: "无法开始读取原视频：\(message)")
            case let .writerCouldNotStart(message):
                return String(localized: "无法开始写入人声版视频：\(message)")
            case let .readerFailed(message):
                return String(localized: "读取原视频失败：\(message)")
            case let .writerFailed(message):
                return String(localized: "生成人声版视频失败：\(message)")
            case .unsupportedPCMFormat:
                return String(localized: "无法将原视频音频转换为 44.1 kHz 立体声")
            case .cannotReadAudioSamples:
                return String(localized: "原视频音轨中没有可读取的音频样本")
            case .cannotCreateAudioFile:
                return String(localized: "无法创建人声临时音频文件")
            case .cannotCreateFFT:
                return String(localized: "当前设备无法初始化音频频谱处理")
            case .exportedFileMissing:
                return String(localized: "人声版视频已生成，但输出文件不存在")
            case .exportedVideoIsInvalid:
                return String(localized: "人声版视频已生成，但视频轨道校验失败")
            case .exportedAudioTrackCountInvalid:
                return String(localized: "人声版视频的音轨数量不正确")
            case .exportedDurationMismatch:
                return String(localized: "人声版视频时长与原视频不一致")
            }
        }
    }

    static let shared = SpleeterForegroundAudioRenderer()

    private static let modelResourceName = "Spleeter2StemsVocalMask-F1536-fp16"

    private var isRendering = false
    private var activeCancellationToken: CancellationToken?

    private init() {}

    /// 检查视频和随 App 打包的模型是否可用于普通视频的人声分离。
    func support(for videoURL: URL) async -> Support {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return .sourceFileMissing
        }
        guard Self.bundledModelURL() != nil else {
            return .modelMissing
        }

        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        do {
            return try await asset.loadTracks(withMediaType: .audio).isEmpty
                ? .noAudioTrack
                : .available
        } catch {
            return .noAudioTrack
        }
    }

    /// 生成仅包含一条人声音轨的新视频，源文件不会被覆盖或删除。
    func render(
        videoURL: URL,
        outputURL: URL? = nil,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !isRendering else {
            throw RenderError.renderAlreadyInProgress
        }
        guard let modelURL = Self.bundledModelURL() else {
            throw RenderError.modelMissing
        }

        let token = CancellationToken()
        isRendering = true
        activeCancellationToken = token
        progress(0)

        defer {
            activeCancellationToken = nil
            isRendering = false
        }

        let worker = RenderWorker(
            videoURL: videoURL,
            requestedOutputURL: outputURL,
            modelURL: modelURL,
            cancellationToken: token,
            progress: progress
        )

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try await worker.run()
            }.value
        } onCancel: {
            token.cancel()
        }
    }

    /// 取消当前人声分离任务。未完成的临时文件和输出文件会由渲染流程清理。
    func cancel() {
        activeCancellationToken?.cancel()
    }

    private static func bundledModelURL() -> URL? {
        if let modelURL = Bundle.main.url(
            forResource: modelResourceName,
            withExtension: "mlmodelc"
        ) {
            return modelURL
        }

        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let modelURL = resourceURL
            .appendingPathComponent(modelResourceName)
            .appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: modelURL.path) {
            return modelURL
        }

        let modelsDirectoryURL = resourceURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(modelResourceName)
            .appendingPathExtension("mlmodelc")
        return FileManager.default.fileExists(atPath: modelsDirectoryURL.path)
            ? modelsDirectoryURL
            : nil
    }
}

private final class CancellationToken: @unchecked Sendable {

    private let lock = NSLock()
    private var isCancelled = false
    private var cancellationHandler: (() -> Void)?

    func cancel() {
        let handler: (() -> Void)?
        lock.lock()
        isCancelled = true
        handler = cancellationHandler
        lock.unlock()
        handler?()
    }

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
    }

    func setCancellationHandler(_ handler: (() -> Void)?) {
        let shouldRunImmediately: Bool
        lock.lock()
        cancellationHandler = handler
        shouldRunImmediately = isCancelled && handler != nil
        lock.unlock()
        if shouldRunImmediately {
            handler?()
        }
    }
}

private enum ModelLoader {

    static let inputName = "magnitude"
    static let outputName = "vocal_mask"
    static let expectedShape = [1, 2, 512, 1536]

    static func loadModel(at url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw SpleeterForegroundAudioRenderer.RenderError.modelLoadFailed(
                message: error.localizedDescription
            )
        }

        guard let input = model.modelDescription.inputDescriptionsByName[inputName],
              input.type == .multiArray,
              let inputConstraint = input.multiArrayConstraint,
              inputConstraint.dataType == .float32,
              inputConstraint.shape.map(\.intValue) == expectedShape,
              let output = model.modelDescription.outputDescriptionsByName[outputName],
              output.type == .multiArray,
              let outputConstraint = output.multiArrayConstraint,
              outputConstraint.dataType == .float32,
              outputConstraint.shape.map(\.intValue) == expectedShape else {
            throw SpleeterForegroundAudioRenderer.RenderError.modelInvalid
        }
        return model
    }
}

private final class RenderWorker: @unchecked Sendable {

    private typealias RenderError = SpleeterForegroundAudioRenderer.RenderError

    private struct TransferTrack {
        let source: AVAssetReaderOutput
        let destination: AVAssetWriterInput
        let reportsProgress: Bool
    }

    private let videoURL: URL
    private let requestedOutputURL: URL?
    private let modelURL: URL
    private let cancellationToken: CancellationToken
    private let progress: (Double) -> Void

    init(
        videoURL: URL,
        requestedOutputURL: URL?,
        modelURL: URL,
        cancellationToken: CancellationToken,
        progress: @escaping (Double) -> Void
    ) {
        self.videoURL = videoURL
        self.requestedOutputURL = requestedOutputURL
        self.modelURL = modelURL
        self.cancellationToken = cancellationToken
        self.progress = progress
    }

    func run() async throws -> URL {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RenderError.sourceFileMissing
        }

        let destinationURL = requestedOutputURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-foreground-spleeter")
                .appendingPathExtension("mov")
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "mov" else {
            throw RenderError.outputMustBeMovie
        }
        guard videoURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw RenderError.sourceAndOutputAreSame
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw RenderError.outputAlreadyExists
        }

        let temporaryAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-spleeter-vocals")
            .appendingPathExtension("caf")
        var shouldRemoveOutput = true
        defer {
            cancellationToken.setCancellationHandler(nil)
            try? FileManager.default.removeItem(at: temporaryAudioURL)
            if shouldRemoveOutput {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        try cancellationToken.check()
        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        async let loadedDuration = asset.load(.duration)
        async let loadedVideoTracks = asset.loadTracks(withMediaType: .video)
        async let loadedAudioTracks = asset.loadTracks(withMediaType: .audio)

        let duration = try await loadedDuration
        let videoTracks = try await loadedVideoTracks
        let audioTracks = try await loadedAudioTracks
        guard duration.isValid,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0 else {
            throw RenderError.invalidDuration
        }
        guard !videoTracks.isEmpty else {
            throw RenderError.missingVideoTrack
        }
        guard !audioTracks.isEmpty else {
            throw RenderError.noAudioTrack
        }

        try cancellationToken.check()
        let model = try ModelLoader.loadModel(at: modelURL)
        try cancellationToken.check()
        await reportProgress(0.01)

        try await separateVocals(
            from: asset,
            audioTracks: audioTracks,
            duration: duration,
            model: model,
            outputURL: temporaryAudioURL
        )
        try cancellationToken.check()

        try await muxVideo(
            asset: asset,
            videoTracks: videoTracks,
            vocalAudioURL: temporaryAudioURL,
            duration: duration,
            destinationURL: destinationURL
        )
        try cancellationToken.check()

        try await validateExportedFile(
            at: destinationURL,
            expectedDuration: duration,
            expectedVideoTrackCount: videoTracks.count
        )
        try cancellationToken.check()

        await reportProgress(1)
        shouldRemoveOutput = false
        return destinationURL
    }

    private func separateVocals(
        from asset: AVAsset,
        audioTracks: [AVAssetTrack],
        duration: CMTime,
        model: MLModel,
        outputURL: URL
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SpleeterEngine.sampleRate,
            AVNumberOfChannelsKey: SpleeterEngine.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        var selectedAudioTrack = audioTracks[0]
        for audioTrack in audioTracks {
            if (try? await audioTrack.load(.isEnabled)) == true {
                selectedAudioTrack = audioTrack
                break
            }
        }
        let audioOutput = AVAssetReaderTrackOutput(
            track: selectedAudioTrack,
            outputSettings: outputSettings
        )
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw RenderError.cannotCreateReaderOutput
        }
        reader.add(audioOutput)

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SpleeterEngine.sampleRate,
            channels: AVAudioChannelCount(SpleeterEngine.channelCount),
            interleaved: false
        ) else {
            throw RenderError.cannotCreateAudioFile
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: processingFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw RenderError.cannotCreateAudioFile
        }

        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw RenderError.invalidDuration
        }
        let expectedFrameCount = max(
            1,
            Int64((durationSeconds * SpleeterEngine.sampleRate).rounded())
        )

        cancellationToken.setCancellationHandler {
            reader.cancelReading()
        }
        defer {
            cancellationToken.setCancellationHandler(nil)
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        guard reader.startReading() else {
            throw RenderError.readerCouldNotStart(
                message: reader.error?.localizedDescription
                    ?? String(localized: "未知错误")
            )
        }

        let stream = PCMStreamReader(
            reader: reader,
            output: audioOutput,
            maximumTimelineFrame: expectedFrameCount,
            cancellationToken: cancellationToken
        )
        let engine = try SpleeterEngine(model: model)
        var overlapAccumulator = ChunkOverlapAccumulator()

        var currentWindow = try stream.readFrames(
            maximumCount: SpleeterEngine.chunkSampleCount
        )
        guard currentWindow.count > 0, stream.hasDecodedSamples else {
            throw RenderError.cannotReadAudioSamples
        }

        var totalTimelineFramesRead = Int64(currentWindow.count)
        var framesWritten: Int64 = 0
        var chunkIndex = 0

        while true {
            try cancellationToken.check()

            let paddedWindow = currentWindow.zeroPadded(
                to: SpleeterEngine.chunkSampleCount
            )
            let separated = try engine.separateVocals(
                left: paddedWindow.left,
                right: paddedWindow.right,
                cancellationToken: cancellationToken
            )

            let retainedStart = min(
                SpleeterEngine.chunkStrideSampleCount,
                currentWindow.count
            )
            let retainedLeft = Array(currentWindow.left.dropFirst(retainedStart))
            let retainedRight = Array(currentWindow.right.dropFirst(retainedStart))
            let newlyRead = try stream.readFrames(
                maximumCount: SpleeterEngine.chunkStrideSampleCount
            )
            let hasNextChunk = newlyRead.count > 0

            overlapAccumulator.add(
                separated,
                isFirstChunk: chunkIndex == 0,
                isLastChunk: !hasNextChunk
            )

            if hasNextChunk {
                let writableCount = Int(min(
                    Int64(SpleeterEngine.chunkStrideSampleCount),
                    max(0, expectedFrameCount - framesWritten)
                ))
                if writableCount > 0 {
                    try overlapAccumulator.writeFirstFrames(
                        writableCount,
                        to: audioFile,
                        format: processingFormat
                    )
                    framesWritten += Int64(writableCount)
                }
                overlapAccumulator.discardFirstFrames(
                    SpleeterEngine.chunkStrideSampleCount
                )

                totalTimelineFramesRead += Int64(newlyRead.count)
                currentWindow = StereoSamples(
                    left: retainedLeft + newlyRead.left,
                    right: retainedRight + newlyRead.right
                )
                chunkIndex += 1

                let separationProgress = min(
                    0.79,
                    0.01 + 0.78 * Double(totalTimelineFramesRead) / Double(expectedFrameCount)
                )
                await reportProgress(separationProgress)
            } else {
                let remainingSourceFrames = max(
                    0,
                    min(expectedFrameCount, totalTimelineFramesRead) - framesWritten
                )
                if remainingSourceFrames > 0 {
                    try overlapAccumulator.writeFirstFrames(
                        Int(remainingSourceFrames),
                        to: audioFile,
                        format: processingFormat
                    )
                    framesWritten += remainingSourceFrames
                }
                break
            }

            if framesWritten >= expectedFrameCount {
                break
            }
        }

        if framesWritten < expectedFrameCount {
            try writeSilence(
                frameCount: expectedFrameCount - framesWritten,
                to: audioFile,
                format: processingFormat
            )
        }

        try cancellationToken.check()
        if reader.status == .failed {
            throw RenderError.readerFailed(
                message: reader.error?.localizedDescription
                    ?? String(localized: "音频读取失败")
            )
        }
        await reportProgress(0.8)
    }

    private func muxVideo(
        asset: AVAsset,
        videoTracks: [AVAssetTrack],
        vocalAudioURL: URL,
        duration: CMTime,
        destinationURL: URL
    ) async throws {
        let vocalAsset = AVURLAsset(
            url: vocalAudioURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let vocalTrack = try await vocalAsset
            .loadTracks(withMediaType: .audio)
            .first else {
            throw RenderError.cannotReadAudioSamples
        }

        let videoReader = try AVAssetReader(asset: asset)
        let audioReader = try AVAssetReader(asset: vocalAsset)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        var transferTracks: [TransferTrack] = []

        for videoTrack in videoTracks {
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard videoReader.canAdd(output) else {
                throw RenderError.cannotCreateReaderOutput
            }

            let formatDescription = try await videoTrack
                .load(.formatDescriptions)
                .first
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            input.transform = try await videoTrack.load(.preferredTransform)
            guard writer.canAdd(input) else {
                throw RenderError.cannotCreateWriterInput
            }

            videoReader.add(output)
            writer.add(input)
            transferTracks.append(
                TransferTrack(
                    source: output,
                    destination: input,
                    reportsProgress: false
                )
            )
        }

        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SpleeterEngine.sampleRate,
            AVNumberOfChannelsKey: SpleeterEngine.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioOutput = AVAssetReaderTrackOutput(
            track: vocalTrack,
            outputSettings: audioOutputSettings
        )
        audioOutput.alwaysCopiesSampleData = false
        guard audioReader.canAdd(audioOutput) else {
            throw RenderError.cannotCreateReaderOutput
        }

        let audioInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SpleeterEngine.sampleRate,
            AVNumberOfChannelsKey: SpleeterEngine.channelCount,
            AVEncoderBitRateKey: 192_000
        ]
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioInputSettings,
            sourceFormatHint: nil
        )
        guard writer.canAdd(audioInput) else {
            throw RenderError.cannotCreateWriterInput
        }
        audioReader.add(audioOutput)
        writer.add(audioInput)
        transferTracks.append(
            TransferTrack(
                source: audioOutput,
                destination: audioInput,
                reportsProgress: true
            )
        )

        cancellationToken.setCancellationHandler {
            videoReader.cancelReading()
            audioReader.cancelReading()
        }
        defer {
            cancellationToken.setCancellationHandler(nil)
            if videoReader.status == .reading {
                videoReader.cancelReading()
            }
            if audioReader.status == .reading {
                audioReader.cancelReading()
            }
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        try cancellationToken.check()
        guard videoReader.startReading() else {
            throw RenderError.readerCouldNotStart(
                message: videoReader.error?.localizedDescription
                    ?? String(localized: "视频读取失败")
            )
        }
        guard audioReader.startReading() else {
            videoReader.cancelReading()
            throw RenderError.readerCouldNotStart(
                message: audioReader.error?.localizedDescription
                    ?? String(localized: "音频读取失败")
            )
        }
        guard writer.startWriting() else {
            videoReader.cancelReading()
            audioReader.cancelReading()
            throw RenderError.writerCouldNotStart(
                message: writer.error?.localizedDescription
                    ?? String(localized: "未知错误")
            )
        }
        writer.startSession(atSourceTime: .zero)

        try await transferSamples(
            transferTracks,
            duration: duration,
            videoReader: videoReader,
            audioReader: audioReader,
            writer: writer
        )
        try cancellationToken.check()

        guard videoReader.status == .completed else {
            throw RenderError.readerFailed(
                message: videoReader.error?.localizedDescription
                    ?? String(localized: "视频读取未正常完成")
            )
        }
        guard audioReader.status == .completed else {
            throw RenderError.readerFailed(
                message: audioReader.error?.localizedDescription
                    ?? String(localized: "音频读取未正常完成")
            )
        }

        cancellationToken.setCancellationHandler {
            writer.cancelWriting()
        }
        await writer.finishWriting()
        cancellationToken.setCancellationHandler(nil)
        try cancellationToken.check()
        guard writer.status == .completed else {
            throw RenderError.writerFailed(
                message: writer.error?.localizedDescription
                    ?? String(localized: "写入未正常完成")
            )
        }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw RenderError.exportedFileMissing
        }
    }

    private func transferSamples(
        _ tracks: [TransferTrack],
        duration: CMTime,
        videoReader: AVAssetReader,
        audioReader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws {
        let queue = DispatchQueue(
            label: "com.teleprompter.spleeter-mux",
            qos: .userInitiated
        )
        let durationSeconds = duration.seconds

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            var completedTracks = Array(repeating: false, count: tracks.count)
            var remainingTrackCount = tracks.count
            var didResume = false
            var lastReportedProgress = 0.8

            func finishTrack(at index: Int) {
                guard !completedTracks[index] else { return }
                completedTracks[index] = true
                tracks[index].destination.markAsFinished()
                remainingTrackCount -= 1
                if remainingTrackCount == 0, !didResume {
                    didResume = true
                    continuation.resume()
                }
            }

            func fail(_ error: Error) {
                guard !didResume else { return }
                didResume = true
                videoReader.cancelReading()
                audioReader.cancelReading()
                writer.cancelWriting()
                continuation.resume(throwing: error)
            }

            cancellationToken.setCancellationHandler {
                queue.async {
                    fail(CancellationError())
                }
            }

            for index in tracks.indices {
                let track = tracks[index]
                track.destination.requestMediaDataWhenReady(on: queue) {
                    guard !didResume, !completedTracks[index] else { return }

                    while track.destination.isReadyForMoreMediaData {
                        guard let sampleBuffer = track.source.copyNextSampleBuffer() else {
                            finishTrack(at: index)
                            return
                        }
                        guard track.destination.append(sampleBuffer) else {
                            fail(
                                RenderError.writerFailed(
                                    message: writer.error?.localizedDescription
                                        ?? String(localized: "无法写入媒体样本")
                                )
                            )
                            return
                        }

                        guard track.reportsProgress,
                              durationSeconds.isFinite,
                              durationSeconds > 0 else { continue }

                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
                        let completedTime = sampleDuration.isValid && sampleDuration.isNumeric
                            ? CMTimeAdd(presentationTime, sampleDuration)
                            : presentationTime
                        let seconds = completedTime.seconds
                        guard seconds.isFinite else { continue }

                        let fraction = min(
                            0.98,
                            0.8 + 0.18 * max(0, seconds / durationSeconds)
                        )
                        guard fraction - lastReportedProgress >= 0.01 else { continue }
                        lastReportedProgress = fraction
                        Task { @MainActor [progress] in
                            progress(fraction)
                        }
                    }
                }
            }
        }
    }

    private func writeSilence(
        frameCount: Int64,
        to audioFile: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        var remaining = frameCount
        while remaining > 0 {
            try cancellationToken.check()
            let count = Int(min(remaining, 16_384))
            try writeStereoSamples(
                StereoSamples(
                    left: [Float](repeating: 0, count: count),
                    right: [Float](repeating: 0, count: count)
                ),
                to: audioFile,
                format: format
            )
            remaining -= Int64(count)
        }
    }

    private func validateExportedFile(
        at outputURL: URL,
        expectedDuration: CMTime,
        expectedVideoTrackCount: Int
    ) async throws {
        let exportedAsset = AVURLAsset(
            url: outputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        async let loadedDuration = exportedAsset.load(.duration)
        async let loadedVideoTracks = exportedAsset.loadTracks(withMediaType: .video)
        async let loadedAudioTracks = exportedAsset.loadTracks(withMediaType: .audio)

        let outputDuration = try await loadedDuration
        let outputVideoTracks = try await loadedVideoTracks
        let outputAudioTracks = try await loadedAudioTracks
        guard outputDuration.isValid,
              outputDuration.isNumeric,
              CMTimeCompare(outputDuration, .zero) > 0,
              outputVideoTracks.count == expectedVideoTrackCount else {
            throw RenderError.exportedVideoIsInvalid
        }
        guard outputAudioTracks.count == 1 else {
            throw RenderError.exportedAudioTrackCountInvalid
        }

        let expectedSeconds = expectedDuration.seconds
        let outputSeconds = outputDuration.seconds
        let audioTimeRange = try await outputAudioTracks[0].load(.timeRange)
        let audioSeconds = audioTimeRange.duration.seconds
        guard expectedSeconds.isFinite,
              outputSeconds.isFinite,
              audioSeconds.isFinite,
              abs(outputSeconds - expectedSeconds) <= 0.25,
              abs(audioSeconds - expectedSeconds) <= 0.25 else {
            throw RenderError.exportedDurationMismatch
        }
    }

    private func reportProgress(_ value: Double) async {
        let clampedValue = min(1, max(0, value))
        await MainActor.run {
            progress(clampedValue)
        }
    }
}

private struct StereoSamples {
    var left: [Float]
    var right: [Float]

    var count: Int {
        min(left.count, right.count)
    }

    func zeroPadded(to targetCount: Int) -> StereoSamples {
        guard count < targetCount else {
            return StereoSamples(
                left: Array(left.prefix(targetCount)),
                right: Array(right.prefix(targetCount))
            )
        }

        let paddingCount = targetCount - count
        return StereoSamples(
            left: left + [Float](repeating: 0, count: paddingCount),
            right: right + [Float](repeating: 0, count: paddingCount)
        )
    }
}

private final class PCMStreamReader {

    private typealias RenderError = SpleeterForegroundAudioRenderer.RenderError

    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let maximumTimelineFrame: Int64
    private let cancellationToken: CancellationToken

    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    private var pendingOffset = 0
    private var pendingSilenceFrameCount: Int64 = 0
    private var appendedTimelineFrame: Int64 = 0
    private var reachedEnd = false

    private(set) var hasDecodedSamples = false

    init(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        maximumTimelineFrame: Int64,
        cancellationToken: CancellationToken
    ) {
        self.reader = reader
        self.output = output
        self.maximumTimelineFrame = maximumTimelineFrame
        self.cancellationToken = cancellationToken
    }

    func readFrames(maximumCount: Int) throws -> StereoSamples {
        guard maximumCount > 0 else {
            return StereoSamples(left: [], right: [])
        }

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(maximumCount)
        right.reserveCapacity(maximumCount)

        while left.count < maximumCount {
            try cancellationToken.check()

            if pendingSilenceFrameCount > 0 {
                let count = Int(min(
                    pendingSilenceFrameCount,
                    Int64(maximumCount - left.count)
                ))
                left.append(contentsOf: repeatElement(0, count: count))
                right.append(contentsOf: repeatElement(0, count: count))
                pendingSilenceFrameCount -= Int64(count)
                continue
            }

            let available = min(pendingLeft.count, pendingRight.count) - pendingOffset
            if available > 0 {
                let count = min(available, maximumCount - left.count)
                left.append(contentsOf: pendingLeft[pendingOffset ..< pendingOffset + count])
                right.append(contentsOf: pendingRight[pendingOffset ..< pendingOffset + count])
                pendingOffset += count
                compactPendingSamplesIfNeeded()
                continue
            }

            guard !reachedEnd, appendedTimelineFrame < maximumTimelineFrame else {
                break
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                reachedEnd = true
                if reader.status == .failed {
                    throw RenderError.readerFailed(
                        message: reader.error?.localizedDescription
                            ?? String(localized: "音频读取失败")
                    )
                }
                try cancellationToken.check()
                break
            }
            try append(sampleBuffer)
        }

        return StereoSamples(left: left, right: right)
    }

    private func append(_ sampleBuffer: CMSampleBuffer) throws {
        let samples = try Self.extractInterleavedStereoFloatSamples(sampleBuffer)
        guard samples.count > 0 else { return }
        hasDecodedSamples = true

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sourceStartFrame: Int64
        if presentationTime.isValid,
           presentationTime.isNumeric,
           presentationTime.seconds.isFinite {
            sourceStartFrame = Int64(
                (presentationTime.seconds * SpleeterEngine.sampleRate).rounded()
            )
        } else {
            sourceStartFrame = appendedTimelineFrame
        }
        let startFrame = max(0, sourceStartFrame)

        if startFrame > appendedTimelineFrame + 1 {
            pendingSilenceFrameCount += min(
                startFrame - appendedTimelineFrame,
                maximumTimelineFrame - appendedTimelineFrame
            )
            appendedTimelineFrame = min(startFrame, maximumTimelineFrame)
        }

        let overlapFrameCount = max(0, appendedTimelineFrame - sourceStartFrame)
        let sourceOffset = Int(min(Int64(samples.count), overlapFrameCount))
        guard sourceOffset < samples.count,
              appendedTimelineFrame < maximumTimelineFrame else {
            return
        }

        let appendCount = Int(min(
            Int64(samples.count - sourceOffset),
            maximumTimelineFrame - appendedTimelineFrame
        ))
        guard appendCount > 0 else { return }

        pendingLeft.removeAll(keepingCapacity: true)
        pendingRight.removeAll(keepingCapacity: true)
        pendingOffset = 0
        pendingLeft.reserveCapacity(appendCount)
        pendingRight.reserveCapacity(appendCount)
        for index in sourceOffset ..< sourceOffset + appendCount {
            pendingLeft.append(samples.left[index])
            pendingRight.append(samples.right[index])
        }
        appendedTimelineFrame += Int64(appendCount)
    }

    private func compactPendingSamplesIfNeeded() {
        guard pendingOffset >= pendingLeft.count else { return }
        pendingLeft.removeAll(keepingCapacity: true)
        pendingRight.removeAll(keepingCapacity: true)
        pendingOffset = 0
    }

    private static func extractInterleavedStereoFloatSamples(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> StereoSamples {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )?.pointee,
              streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mSampleRate == SpleeterEngine.sampleRate,
              Int(streamDescription.mChannelsPerFrame) == SpleeterEngine.channelCount,
              streamDescription.mBitsPerChannel == 32,
              Int(streamDescription.mBytesPerFrame) == MemoryLayout<Float>.size * 2,
              streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw RenderError.unsupportedPCMFormat
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            return StereoSamples(left: [], right: [])
        }
        let valueCount = frameCount * 2
        let byteCount = valueCount * MemoryLayout<Float>.size
        guard CMBlockBufferGetDataLength(dataBuffer) >= byteCount else {
            throw RenderError.unsupportedPCMFormat
        }

        var interleaved = [Float](repeating: 0, count: valueCount)
        let status = interleaved.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RenderError.unsupportedPCMFormat
        }

        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frame in 0 ..< frameCount {
            left[frame] = interleaved[frame * 2]
            right[frame] = interleaved[frame * 2 + 1]
        }
        return StereoSamples(left: left, right: right)
    }
}

private final class SpleeterEngine {

    private typealias RenderError = SpleeterForegroundAudioRenderer.RenderError

    static let sampleRate = 44_100.0
    static let channelCount = 2
    static let fftSize = 4_096
    static let hopSize = 1_024
    static let modelFrameCount = 512
    static let modelFrequencyBinCount = 1_536

    /// 官方 Spleeter 使用 no-center、pad_end=false，因此 512 帧需要 527,360 samples。
    static let chunkSampleCount = fftSize + (modelFrameCount - 1) * hopSize
    /// 长视频以 256 个频谱帧为步进，形成约 50% 的块重叠。
    static let chunkStrideSampleCount = 256 * hopSize

    private static let elementCount = channelCount * modelFrameCount * modelFrequencyBinCount
    private static let log2FFTSize = vDSP_Length(12)

    private let model: MLModel
    private let fftSetup: FFTSetup
    private let periodicHannWindow: [Float]
    private let inverseWindowNormalization: [Float]

    init(model: MLModel) throws {
        guard let fftSetup = vDSP_create_fftsetup(
            Self.log2FFTSize,
            FFTRadix(kFFTRadix2)
        ) else {
            throw RenderError.cannotCreateFFT
        }
        self.model = model
        self.fftSetup = fftSetup

        // 与 TensorFlow tf.signal.hann_window(periodic: true) 一致。
        periodicHannWindow = (0 ..< Self.fftSize).map { index in
            0.5 - 0.5 * cosf(2 * .pi * Float(index) / Float(Self.fftSize))
        }

        var normalization = [Float](repeating: 0, count: Self.chunkSampleCount)
        for frame in 0 ..< Self.modelFrameCount {
            let frameStart = frame * Self.hopSize
            for index in 0 ..< Self.fftSize {
                let window = periodicHannWindow[index]
                normalization[frameStart + index] += window * window
            }
        }
        inverseWindowNormalization = normalization
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func separateVocals(
        left: [Float],
        right: [Float],
        cancellationToken: CancellationToken
    ) throws -> StereoSamples {
        guard left.count == Self.chunkSampleCount,
              right.count == Self.chunkSampleCount else {
            throw RenderError.cannotReadAudioSamples
        }

        let magnitude = try MLMultiArray(
            shape: ModelLoader.expectedShape.map { NSNumber(value: $0) },
            dataType: .float32
        )
        guard Self.isContiguous(magnitude), magnitude.count == Self.elementCount else {
            throw RenderError.modelInvalid
        }
        let magnitudePointer = magnitude.dataPointer
            .bindMemory(to: Float.self, capacity: Self.elementCount)

        var spectrumReal = [Float](repeating: 0, count: Self.elementCount)
        var spectrumImaginary = [Float](repeating: 0, count: Self.elementCount)
        var fftReal = [Float](repeating: 0, count: Self.fftSize)
        var fftImaginary = [Float](repeating: 0, count: Self.fftSize)

        for channel in 0 ..< Self.channelCount {
            let channelSamples = channel == 0 ? left : right
            for frame in 0 ..< Self.modelFrameCount {
                if frame.isMultiple(of: 32) {
                    try cancellationToken.check()
                }
                let frameStart = frame * Self.hopSize
                for index in 0 ..< Self.fftSize {
                    fftReal[index] = channelSamples[frameStart + index]
                        * periodicHannWindow[index]
                    fftImaginary[index] = 0
                }

                Self.performFFT(
                    setup: fftSetup,
                    real: &fftReal,
                    imaginary: &fftImaginary,
                    direction: FFTDirection(kFFTDirection_Forward)
                )

                let modelFrameOffset = (
                    channel * Self.modelFrameCount + frame
                ) * Self.modelFrequencyBinCount
                for bin in 0 ..< Self.modelFrequencyBinCount {
                    let index = modelFrameOffset + bin
                    let real = fftReal[bin]
                    let imaginary = fftImaginary[bin]
                    spectrumReal[index] = real
                    spectrumImaginary[index] = imaginary
                    magnitudePointer[index] = hypotf(real, imaginary)
                }
            }
        }

        try cancellationToken.check()
        let prediction: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [
                    ModelLoader.inputName: MLFeatureValue(multiArray: magnitude)
                ]
            )
            prediction = try model.prediction(from: provider)
        } catch {
            throw RenderError.modelPredictionFailed(message: error.localizedDescription)
        }
        try cancellationToken.check()

        guard let mask = prediction.featureValue(
            for: ModelLoader.outputName
        )?.multiArrayValue,
        mask.dataType == .float32,
        mask.shape.map(\.intValue) == ModelLoader.expectedShape,
        mask.count == Self.elementCount,
        Self.isContiguous(mask) else {
            throw RenderError.invalidModelOutput
        }
        let maskPointer = mask.dataPointer
            .bindMemory(to: Float.self, capacity: Self.elementCount)

        var output = StereoSamples(
            left: [Float](repeating: 0, count: Self.chunkSampleCount),
            right: [Float](repeating: 0, count: Self.chunkSampleCount)
        )

        for channel in 0 ..< Self.channelCount {
            for frame in 0 ..< Self.modelFrameCount {
                if frame.isMultiple(of: 32) {
                    try cancellationToken.check()
                }
                fftReal.withUnsafeMutableBufferPointer {
                    $0.initialize(repeating: 0)
                }
                fftImaginary.withUnsafeMutableBufferPointer {
                    $0.initialize(repeating: 0)
                }

                let modelFrameOffset = (
                    channel * Self.modelFrameCount + frame
                ) * Self.modelFrequencyBinCount
                for bin in 0 ..< Self.modelFrequencyBinCount {
                    let index = modelFrameOffset + bin
                    let rawMask = maskPointer[index]
                    let vocalMask = rawMask.isFinite ? min(1, max(0, rawMask)) : 0
                    let real = spectrumReal[index] * vocalMask
                    let imaginary = spectrumImaginary[index] * vocalMask
                    fftReal[bin] = real
                    fftImaginary[bin] = imaginary

                    if bin > 0 {
                        fftReal[Self.fftSize - bin] = real
                        fftImaginary[Self.fftSize - bin] = -imaginary
                    }
                }
                // Spleeter 配置的 mask_extension=zeros：1536...2048 频点保持为零。
                Self.performFFT(
                    setup: fftSetup,
                    real: &fftReal,
                    imaginary: &fftImaginary,
                    direction: FFTDirection(kFFTDirection_Inverse)
                )
                var inverseScale = 1 / Float(Self.fftSize)
                fftReal.withUnsafeMutableBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    vDSP_vsmul(
                        baseAddress,
                        1,
                        &inverseScale,
                        baseAddress,
                        1,
                        vDSP_Length(Self.fftSize)
                    )
                }

                let frameStart = frame * Self.hopSize
                if channel == 0 {
                    for index in 0 ..< Self.fftSize {
                        output.left[frameStart + index] += fftReal[index]
                            * periodicHannWindow[index]
                    }
                } else {
                    for index in 0 ..< Self.fftSize {
                        output.right[frameStart + index] += fftReal[index]
                            * periodicHannWindow[index]
                    }
                }
            }
        }

        for index in 0 ..< Self.chunkSampleCount {
            let normalization = inverseWindowNormalization[index]
            guard normalization > 1e-8 else {
                output.left[index] = 0
                output.right[index] = 0
                continue
            }
            output.left[index] /= normalization
            output.right[index] /= normalization
        }
        return output
    }

    private static func performFFT(
        setup: FFTSetup,
        real: inout [Float],
        imaginary: inout [Float],
        direction: FFTDirection
    ) {
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_fft_zip(
                    setup,
                    &splitComplex,
                    1,
                    log2FFTSize,
                    direction
                )
            }
        }
    }

    private static func isContiguous(_ array: MLMultiArray) -> Bool {
        var expectedStride = 1
        for index in stride(from: array.shape.count - 1, through: 0, by: -1) {
            guard array.strides[index].intValue == expectedStride else {
                return false
            }
            expectedStride *= array.shape[index].intValue
        }
        return true
    }
}

private struct ChunkOverlapAccumulator {

    private static let sampleCount = SpleeterEngine.chunkSampleCount
    private static let strideSampleCount = SpleeterEngine.chunkStrideSampleCount
    private static let overlapSampleCount = sampleCount - strideSampleCount

    private var left = [Float](repeating: 0, count: sampleCount)
    private var right = [Float](repeating: 0, count: sampleCount)
    private var weights = [Float](repeating: 0, count: sampleCount)

    mutating func add(
        _ samples: StereoSamples,
        isFirstChunk: Bool,
        isLastChunk: Bool
    ) {
        let count = min(Self.sampleCount, samples.count)
        for index in 0 ..< count {
            var weight: Float = 1
            if !isFirstChunk, index < Self.overlapSampleCount {
                let phase = Float(index) / Float(Self.overlapSampleCount)
                weight *= 0.5 - 0.5 * cosf(.pi * phase)
            }
            if !isLastChunk, index >= Self.strideSampleCount {
                let phase = Float(index - Self.strideSampleCount)
                    / Float(Self.overlapSampleCount)
                weight *= 0.5 + 0.5 * cosf(.pi * phase)
            }
            left[index] += samples.left[index] * weight
            right[index] += samples.right[index] * weight
            weights[index] += weight
        }
    }

    mutating func writeFirstFrames(
        _ frameCount: Int,
        to audioFile: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        let count = min(frameCount, Self.sampleCount)
        var output = StereoSamples(
            left: [Float](repeating: 0, count: count),
            right: [Float](repeating: 0, count: count)
        )
        for index in 0 ..< count where weights[index] > 1e-8 {
            let leftSample = left[index] / weights[index]
            let rightSample = right[index] / weights[index]
            output.left[index] = leftSample.isFinite
                ? min(1, max(-1, leftSample))
                : 0
            output.right[index] = rightSample.isFinite
                ? min(1, max(-1, rightSample))
                : 0
        }
        try writeStereoSamples(output, to: audioFile, format: format)
    }

    mutating func discardFirstFrames(_ frameCount: Int) {
        let count = min(frameCount, Self.sampleCount)
        guard count > 0 else { return }
        left.removeFirst(count)
        right.removeFirst(count)
        weights.removeFirst(count)
        left.append(contentsOf: repeatElement(0, count: count))
        right.append(contentsOf: repeatElement(0, count: count))
        weights.append(contentsOf: repeatElement(0, count: count))
    }
}

private func writeStereoSamples(
    _ samples: StereoSamples,
    to audioFile: AVAudioFile,
    format: AVAudioFormat
) throws {
    let frameCount = samples.count
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(
              pcmFormat: format,
              frameCapacity: AVAudioFrameCount(frameCount)
          ),
          let channelData = buffer.floatChannelData else {
        throw SpleeterForegroundAudioRenderer.RenderError.cannotCreateAudioFile
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    samples.left.withUnsafeBufferPointer { source in
        channelData[0].update(from: source.baseAddress!, count: frameCount)
    }
    samples.right.withUnsafeBufferPointer { source in
        channelData[1].update(from: source.baseAddress!, count: frameCount)
    }
    try audioFile.write(from: buffer)
}
