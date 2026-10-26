@preconcurrency import AVFoundation
@preconcurrency import Cinematic

/// 将空间音频视频中的前景人声烘焙为唯一音轨，不改写源视频。
@MainActor
final class ForegroundAudioRenderer {

    enum Support: Equatable {
        case available
        case unsupportedOS
        case unsupportedDevice
        case missingSpatialAudio
        case noAudioTrack

        var localizedDescription: String {
            switch self {
            case .available:
                return String(localized: "支持仅保留前景人声")
            case .unsupportedOS:
                return String(localized: "仅保留前景人声需要 iOS 26 或更高版本")
            case .unsupportedDevice:
                return String(localized: "当前设备不支持本地前景人声分离")
            case .missingSpatialAudio:
                return String(localized: "该视频不包含可用于分离的空间音频")
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
        case unsupportedOS
        case unsupportedDevice
        case missingSpatialAudio
        case noAudioTrack
        case missingVideoTrack
        case missingVideoFormat
        case invalidDuration
        case cannotCreateReaderOutput
        case cannotCreateWriterInput
        case readerCouldNotStart(message: String)
        case writerCouldNotStart(message: String)
        case readerFailed(message: String)
        case writerFailed(message: String)
        case exportedFileMissing
        case exportedVideoIsInvalid
        case exportedAudioTrackCountInvalid
        case exportedDurationMismatch

        var errorDescription: String? {
            switch self {
            case .renderAlreadyInProgress:
                return String(localized: "已有前景人声视频正在生成")
            case .sourceFileMissing:
                return String(localized: "原视频文件不存在")
            case .sourceAndOutputAreSame:
                return String(localized: "前景人声版输出路径不能与原视频相同")
            case .outputMustBeMovie:
                return String(localized: "前景人声版视频必须使用 .mov 文件")
            case .outputAlreadyExists:
                return String(localized: "前景人声版输出文件已存在，为避免覆盖已停止导出")
            case .unsupportedOS:
                return Support.unsupportedOS.localizedDescription
            case .unsupportedDevice:
                return Support.unsupportedDevice.localizedDescription
            case .missingSpatialAudio:
                return Support.missingSpatialAudio.localizedDescription
            case .noAudioTrack:
                return Support.noAudioTrack.localizedDescription
            case .missingVideoTrack:
                return String(localized: "原视频不包含可用的视频轨道")
            case .missingVideoFormat:
                return String(localized: "无法读取原视频编码格式")
            case .invalidDuration:
                return String(localized: "无法读取原视频时长")
            case .cannotCreateReaderOutput:
                return String(localized: "当前视频无法创建前景人声读取轨道")
            case .cannotCreateWriterInput:
                return String(localized: "当前设备无法创建前景人声输出轨道")
            case let .readerCouldNotStart(message):
                return String(localized: "无法开始读取原视频：\(message)")
            case let .writerCouldNotStart(message):
                return String(localized: "无法开始写入前景人声版视频：\(message)")
            case let .readerFailed(message):
                return String(localized: "读取原视频失败：\(message)")
            case let .writerFailed(message):
                return String(localized: "生成前景人声版视频失败：\(message)")
            case .exportedFileMissing:
                return String(localized: "前景人声版视频已生成，但输出文件不存在")
            case .exportedVideoIsInvalid:
                return String(localized: "前景人声版视频已生成，但视频轨道校验失败")
            case .exportedAudioTrackCountInvalid:
                return String(localized: "前景人声版视频的音轨数量不正确")
            case .exportedDurationMismatch:
                return String(localized: "前景人声版视频时长与原视频不一致")
            }
        }
    }

    static let shared = ForegroundAudioRenderer()

    private struct TransferTrack {
        let source: AVAssetReaderOutput
        let destination: AVAssetWriterInput
        let reportsProgress: Bool
    }

    private final class TransferContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return result != nil
        }

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                resume(continuation, with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(with result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            if let continuation {
                resume(continuation, with: result)
            }
        }

        private func resume(
            _ continuation: CheckedContinuation<Void, Error>,
            with result: Result<Void, Error>
        ) {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?
    private var activeTransferContinuation: TransferContinuation?
    private var cancellationRequested = false
    private var isRendering = false

    private init() {}

    /// 检查当前系统、设备和视频是否支持 Apple Audio Mix 前景人声分离。
    func support(for videoURL: URL) async -> Support {
        guard #available(iOS 26.0, *) else {
            return .unsupportedOS
        }
        guard CNAssetSpatialAudioInfo.isSupported else {
            return .unsupportedDevice
        }

        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        do {
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                return .noAudioTrack
            }
        } catch {
            return .noAudioTrack
        }

        guard await CNAssetSpatialAudioInfo.assetContainsSpatialAudio(asset: asset) else {
            return .missingSpatialAudio
        }
        return .available
    }

    /// 生成仅包含前景人声的新视频。视频轨道压缩数据原样复制，音频仅写入处理后的立体声轨道。
    func render(
        videoURL: URL,
        outputURL: URL? = nil,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !isRendering else {
            throw RenderError.renderAlreadyInProgress
        }

        isRendering = true
        cancellationRequested = false
        progress(0)

        defer {
            activeReader = nil
            activeWriter = nil
            activeTransferContinuation = nil
            cancellationRequested = false
            isRendering = false
        }

        return try await withTaskCancellationHandler {
            guard #available(iOS 26.0, *) else {
                throw RenderError.unsupportedOS
            }
            return try await performRender(
                videoURL: videoURL,
                requestedOutputURL: outputURL,
                progress: progress
            )
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    /// 取消当前任务。源视频不会被删除，未完成的输出会由渲染流程清理。
    func cancel() {
        cancellationRequested = true
        activeReader?.cancelReading()
        activeWriter?.cancelWriting()
        activeTransferContinuation?.finish(with: .failure(CancellationError()))
    }

    @available(iOS 26.0, *)
    private func performRender(
        videoURL: URL,
        requestedOutputURL: URL?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RenderError.sourceFileMissing
        }
        try checkCancellation()

        let destinationURL = requestedOutputURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-foreground")
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

        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        guard CNAssetSpatialAudioInfo.isSupported else {
            throw RenderError.unsupportedDevice
        }

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
        try checkCancellation()

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
        guard await CNAssetSpatialAudioInfo.assetContainsSpatialAudio(asset: asset) else {
            throw RenderError.missingSpatialAudio
        }

        let audioInfo = try await CNAssetSpatialAudioInfo(asset: asset)
        try checkCancellation()

        let audioMix = audioInfo.audioMix(
            effectIntensity: 1,
            renderingStyle: .cinematicForegroundStem
        )
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        activeReader = reader
        activeWriter = writer
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        var transferTracks: [TransferTrack] = []

        let foregroundAudioOutput = AVAssetReaderAudioMixOutput(
            audioTracks: [audioInfo.defaultSpatialAudioTrack],
            audioSettings: audioInfo.assetReaderOutputSettings(for: .stereo)
        )
        foregroundAudioOutput.audioMix = audioMix
        foregroundAudioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(foregroundAudioOutput) else {
            throw RenderError.cannotCreateReaderOutput
        }

        let foregroundAudioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioInfo.assetWriterInputSettings(for: .stereo)
        )
        guard writer.canAdd(foregroundAudioInput) else {
            throw RenderError.cannotCreateWriterInput
        }
        reader.add(foregroundAudioOutput)
        writer.add(foregroundAudioInput)
        transferTracks.append(
            TransferTrack(
                source: foregroundAudioOutput,
                destination: foregroundAudioInput,
                reportsProgress: true
            )
        )

        for videoTrack in videoTracks {
            guard let sourceFormatHint = try await videoTrack.load(.formatDescriptions).first else {
                throw RenderError.missingVideoFormat
            }
            let videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: nil
            )
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                throw RenderError.cannotCreateReaderOutput
            }

            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: sourceFormatHint
            )
            videoInput.transform = try await videoTrack.load(.preferredTransform)
            guard writer.canAdd(videoInput) else {
                throw RenderError.cannotCreateWriterInput
            }

            reader.add(videoOutput)
            writer.add(videoInput)
            transferTracks.append(
                TransferTrack(
                    source: videoOutput,
                    destination: videoInput,
                    reportsProgress: false
                )
            )
        }

        try checkCancellation()
        guard reader.startReading() else {
            throw RenderError.readerCouldNotStart(
                message: reader.error?.localizedDescription ?? String(localized: "未知错误")
            )
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RenderError.writerCouldNotStart(
                message: writer.error?.localizedDescription ?? String(localized: "未知错误")
            )
        }
        writer.startSession(atSourceTime: .zero)

        try await transferSamples(
            transferTracks,
            duration: duration,
            reader: reader,
            writer: writer,
            progress: progress
        )
        try checkCancellation()

        guard reader.status == .completed else {
            throw RenderError.readerFailed(
                message: reader.error?.localizedDescription ?? String(localized: "读取未正常完成")
            )
        }

        await writer.finishWriting()
        try checkCancellation()
        guard writer.status == .completed else {
            throw RenderError.writerFailed(
                message: writer.error?.localizedDescription ?? String(localized: "写入未正常完成")
            )
        }
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw RenderError.exportedFileMissing
        }

        try await validateExportedFile(
            at: destinationURL,
            expectedDuration: duration
        )
        try checkCancellation()

        progress(1)
        shouldRemoveOutput = false
        return destinationURL
    }

    @available(iOS 26.0, *)
    private func transferSamples(
        _ tracks: [TransferTrack],
        duration: CMTime,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        progress: @escaping (Double) -> Void
    ) async throws {
        let transferQueue = DispatchQueue(
            label: "com.teleprompter.foreground-audio-transfer",
            qos: .userInitiated
        )
        let durationSeconds = duration.seconds
        let transferContinuation = TransferContinuation()
        activeTransferContinuation = transferContinuation
        defer {
            if activeTransferContinuation === transferContinuation {
                activeTransferContinuation = nil
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transferContinuation.install(continuation)
                var completedTracks = Array(repeating: false, count: tracks.count)
                var remainingTrackCount = tracks.count
                var lastReportedProgress = 0.0

                func finishTrack(at index: Int) {
                    guard !transferContinuation.isFinished,
                          !completedTracks[index] else { return }
                    completedTracks[index] = true
                    tracks[index].destination.markAsFinished()
                    remainingTrackCount -= 1
                    if remainingTrackCount == 0 {
                        transferContinuation.finish(with: .success(()))
                    }
                }

                func fail(_ error: Error) {
                    guard !transferContinuation.isFinished else { return }
                    reader.cancelReading()
                    writer.cancelWriting()
                    transferContinuation.finish(with: .failure(error))
                }

                for index in tracks.indices {
                    let track = tracks[index]
                    track.destination.requestMediaDataWhenReady(on: transferQueue) {
                        guard !transferContinuation.isFinished,
                              !completedTracks[index] else { return }

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
                            let completedSeconds = completedTime.seconds
                            guard completedSeconds.isFinite else { continue }

                            let fraction = min(0.98, max(0, completedSeconds / durationSeconds))
                            guard fraction - lastReportedProgress >= 0.01 else { continue }
                            lastReportedProgress = fraction
                            Task { @MainActor in
                                progress(fraction)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
            transferContinuation.finish(with: .failure(CancellationError()))
        }
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func validateExportedFile(
        at outputURL: URL,
        expectedDuration: CMTime
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
              !outputVideoTracks.isEmpty else {
            throw RenderError.exportedVideoIsInvalid
        }
        guard outputAudioTracks.count == 1 else {
            throw RenderError.exportedAudioTrackCountInvalid
        }

        let expectedSeconds = expectedDuration.seconds
        let outputSeconds = outputDuration.seconds
        guard expectedSeconds.isFinite,
              outputSeconds.isFinite,
              abs(outputSeconds - expectedSeconds) <= 0.25 else {
            throw RenderError.exportedDurationMismatch
        }
    }
}
