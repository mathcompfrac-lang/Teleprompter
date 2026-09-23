
import AVFoundation
import QuartzCore
import UIKit

/// 将带时间轴的字幕逐帧烧录进视频。渲染结果始终是新的 `.mov` 文件，不会改写源视频。
@MainActor
final class HardSubtitleRenderer {

    struct Style {
        var fontName: String?
        var fontSizeRatio: CGFloat
        var minimumFontSizeRatio: CGFloat
        var maximumTextWidthRatio: CGFloat
        var bottomMarginRatio: CGFloat
        var horizontalPaddingRatio: CGFloat
        var verticalPaddingRatio: CGFloat
        var maximumLineCount: Int
        var textColor: UIColor
        var backgroundColor: UIColor
        var cornerRadiusRatio: CGFloat

        static let `default` = Style(
            fontName: nil,
            fontSizeRatio: 0.052,
            minimumFontSizeRatio: 0.030,
            maximumTextWidthRatio: 0.88,
            bottomMarginRatio: 0.075,
            horizontalPaddingRatio: 0.022,
            verticalPaddingRatio: 0.012,
            maximumLineCount: 2,
            textColor: .white,
            backgroundColor: UIColor.black.withAlphaComponent(0.68),
            cornerRadiusRatio: 0.012
        )
    }

    enum RenderError: LocalizedError {
        case renderAlreadyInProgress
        case sourceFileMissing
        case sourceAndOutputAreSame
        case outputMustBeMovie
        case outputAlreadyExists
        case invalidVideoDuration
        case missingVideoTrack
        case missingCompositionVideoTrack
        case audioTrackWasNotPreserved
        case emptySubtitles
        case invalidSubtitle(index: Int)
        case invalidRenderSize
        case cannotCreateExportSession
        case movieOutputIsUnsupported
        case exportFailed(message: String)
        case exportedFileMissing
        case exportedVideoIsInvalid
        case exportedDurationMismatch
        case exportedVideoTimingMismatch
        case exportedAudioTimingMismatch

        var errorDescription: String? {
            switch self {
            case .renderAlreadyInProgress:
                return "已有字幕视频正在生成"
            case .sourceFileMissing:
                return "原视频文件不存在"
            case .sourceAndOutputAreSame:
                return "字幕版输出路径不能与原视频相同"
            case .outputMustBeMovie:
                return "字幕版视频必须使用 .mov 文件"
            case .outputAlreadyExists:
                return "字幕版输出文件已存在，为避免覆盖已停止导出"
            case .invalidVideoDuration:
                return "无法读取原视频时长"
            case .missingVideoTrack:
                return "原视频不包含可用的视频轨道"
            case .missingCompositionVideoTrack:
                return "无法创建字幕版视频轨道"
            case .audioTrackWasNotPreserved:
                return "无法保留原视频音轨"
            case .emptySubtitles:
                return "没有可写入视频的字幕"
            case let .invalidSubtitle(index):
                return "第 \(index + 1) 条字幕的时间范围无效"
            case .invalidRenderSize:
                return "无法读取原视频画面尺寸"
            case .cannotCreateExportSession:
                return "当前设备无法创建视频导出任务"
            case .movieOutputIsUnsupported:
                return "当前视频无法导出为 MOV 格式"
            case let .exportFailed(message):
                return "生成字幕版视频失败：\(message)"
            case .exportedFileMissing:
                return "字幕版视频已导出，但输出文件不存在"
            case .exportedVideoIsInvalid:
                return "字幕版视频已导出，但媒体轨道校验失败"
            case .exportedDurationMismatch:
                return "字幕版视频时长与原视频不一致"
            case .exportedVideoTimingMismatch:
                return "字幕版视频轨时间范围与原视频不一致"
            case .exportedAudioTimingMismatch:
                return "字幕版音轨时间范围与原视频不一致"
            }
        }
    }

    static let shared = HardSubtitleRenderer()

    private struct PreparedCue {
        let timeRange: CMTimeRange
        let text: String
    }

    private var activeExportSession: AVAssetExportSession?
    private var progressTask: Task<Void, Never>?
    private var cancellationRequested = false
    private var isRendering = false

    private init() {}

    /// 生成一份带硬字幕的新视频。
    ///
    /// - Parameters:
    ///   - videoURL: 原视频本地文件地址。
    ///   - cues: 已按语音对齐的字幕段。
    ///   - outputURL: 可选的目标地址；为空时在临时目录生成唯一 `.mov` 文件。
    ///   - style: 字幕样式，尺寸按最终视频分辨率等比计算。
    ///   - progress: 在主线程回调 `0...1` 的导出进度。
    /// - Returns: 新生成的字幕版视频地址。
    func render(
        videoURL: URL,
        cues: [SubtitleCue],
        outputURL: URL? = nil,
        style: Style = .default,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !isRendering else {
            throw RenderError.renderAlreadyInProgress
        }

        isRendering = true
        cancellationRequested = false
        progress(0)

        defer {
            progressTask?.cancel()
            progressTask = nil
            activeExportSession = nil
            cancellationRequested = false
            isRendering = false
        }

        return try await withTaskCancellationHandler {
            try await performRender(
                videoURL: videoURL,
                cues: cues,
                requestedOutputURL: outputURL,
                style: style,
                progress: progress
            )
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    /// 取消当前生成任务。已经存在的原视频不会被删除或改写。
    func cancel() {
        cancellationRequested = true
        progressTask?.cancel()
        activeExportSession?.cancelExport()
    }

    private func performRender(
        videoURL: URL,
        cues: [SubtitleCue],
        requestedOutputURL: URL?,
        style: Style,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RenderError.sourceFileMissing
        }
        try checkCancellation()

        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        async let loadedDuration = asset.load(.duration)
        async let loadedVideoTracks = asset.loadTracks(withMediaType: .video)
        async let loadedAudioTracks = asset.loadTracks(withMediaType: .audio)

        let duration = try await loadedDuration
        let sourceVideoTracks = try await loadedVideoTracks
        let sourceAudioTracks = try await loadedAudioTracks
        try checkCancellation()

        guard duration.isValid,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0 else {
            throw RenderError.invalidVideoDuration
        }
        guard let sourceVideoTrack = sourceVideoTracks.first else {
            throw RenderError.missingVideoTrack
        }

        async let loadedNaturalSize = sourceVideoTrack.load(.naturalSize)
        async let loadedPreferredTransform = sourceVideoTrack.load(.preferredTransform)
        async let loadedFrameRate = sourceVideoTrack.load(.nominalFrameRate)

        let naturalSize = try await loadedNaturalSize
        let preferredTransform = try await loadedPreferredTransform
        let nominalFrameRate = try await loadedFrameRate
        try checkCancellation()

        let preparedCues = try prepareCues(cues, videoDuration: duration)
        let destinationURL = try makeDestinationURL(
            sourceURL: videoURL,
            requestedOutputURL: requestedOutputURL
        )

        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        let composition = AVMutableComposition()
        let sourceTimeRange = CMTimeRange(start: .zero, duration: duration)
        try composition.insertTimeRange(sourceTimeRange, of: asset, at: .zero)
        try checkCancellation()

        guard let compositionVideoTrack = composition.tracks(withMediaType: .video).first else {
            throw RenderError.missingCompositionVideoTrack
        }
        if !sourceAudioTracks.isEmpty,
           composition.tracks(withMediaType: .audio).isEmpty {
            throw RenderError.audioTrackWasNotPreserved
        }

        let expectedDuration = try await composition.load(.duration)
        let exportTimeRange = CMTimeRange(start: .zero, duration: expectedDuration)
        let expectedVideoTimeRange = exportTimeRange
        let expectedAudioTimeRange: CMTimeRange?
        if let compositionAudioTrack = composition.tracks(withMediaType: .audio).first {
            let compositionAudioTimeRange = try await compositionAudioTrack.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(
                compositionAudioTimeRange,
                otherRange: exportTimeRange
            )
            expectedAudioTimeRange = intersection.isEmpty
                ? nil
                : CMTimeRange(
                    start: CMTimeSubtract(intersection.start, exportTimeRange.start),
                    duration: intersection.duration
                )
        } else {
            expectedAudioTimeRange = nil
        }

        let geometry = try videoGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let videoComposition = try await makeVideoComposition(
            videoTrack: compositionVideoTrack,
            normalizedTransform: geometry.transform,
            renderSize: geometry.renderSize,
            frameRate: nominalFrameRate,
            duration: expectedDuration,
            cues: preparedCues,
            style: style
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw RenderError.cannotCreateExportSession
        }
        guard exportSession.supportedFileTypes.contains(.mov) else {
            throw RenderError.movieOutputIsUnsupported
        }

        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.timeRange = exportTimeRange
        exportSession.videoComposition = videoComposition
        activeExportSession = exportSession

        try checkCancellation()
        startProgressReporting(exportSession: exportSession, callback: progress)
        do {
            try await exportSession.export(to: destinationURL, as: .mov)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RenderError.exportFailed(message: error.localizedDescription)
        }
        try checkCancellation()

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw RenderError.exportedFileMissing
        }
        try await validateExportedFile(
            at: destinationURL,
            expectedDuration: expectedDuration,
            expectedVideoTimeRange: expectedVideoTimeRange,
            expectedAudioTimeRange: expectedAudioTimeRange,
            frameDuration: videoComposition.frameDuration
        )
        try checkCancellation()

        progress(1)
        shouldRemoveOutput = false
        return destinationURL
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func makeDestinationURL(
        sourceURL: URL,
        requestedOutputURL: URL?
    ) throws -> URL {
        let destinationURL: URL
        if let requestedOutputURL {
            destinationURL = requestedOutputURL
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TeleprompterSubtitleExports", isDirectory: true)
            let sourceName = sourceURL.deletingPathExtension().lastPathComponent
            let safeName = String(sourceName.prefix(60))
            destinationURL = directory.appendingPathComponent(
                "\(safeName)-subtitled-\(UUID().uuidString).mov",
                isDirectory: false
            )
        }

        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "mov" else {
            throw RenderError.outputMustBeMovie
        }

        let resolvedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedSource.path.caseInsensitiveCompare(resolvedDestination.path) != .orderedSame else {
            throw RenderError.sourceAndOutputAreSame
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw RenderError.outputAlreadyExists
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return destinationURL
    }

    private func prepareCues(
        _ cues: [SubtitleCue],
        videoDuration: CMTime
    ) throws -> [PreparedCue] {
        guard !cues.isEmpty else {
            throw RenderError.emptySubtitles
        }

        for (index, cue) in cues.enumerated() {
            let start = cue.timeRange.start
            let end = CMTimeRangeGetEnd(cue.timeRange)
            guard start.isValid,
                  start.isNumeric,
                  end.isValid,
                  end.isNumeric,
                  CMTimeCompare(end, start) > 0 else {
                throw RenderError.invalidSubtitle(index: index)
            }
        }

        let indexedCues = cues.enumerated().sorted {
            let comparison = CMTimeCompare(
                $0.element.timeRange.start,
                $1.element.timeRange.start
            )
            return comparison == 0 ? $0.offset < $1.offset : comparison < 0
        }
        var result: [PreparedCue] = []

        for (_, cue) in indexedCues {
            let rawStart = cue.timeRange.start
            let rawEnd = CMTimeRangeGetEnd(cue.timeRange)

            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = CMTimeCompare(rawStart, .zero) < 0 ? CMTime.zero : rawStart
            let end = CMTimeCompare(rawEnd, videoDuration) > 0 ? videoDuration : rawEnd
            guard CMTimeCompare(end, start) > 0 else { continue }

            // 识别引擎的相邻分段可能因时间戳舍入产生重叠。后一句开始时立即
            // 结束前一句，避免两层文字同时烧录；相同起点时以后返回的分段为准。
            if let previous = result.last,
               CMTimeCompare(start, CMTimeRangeGetEnd(previous.timeRange)) < 0 {
                if CMTimeCompare(start, previous.timeRange.start) > 0 {
                    result[result.count - 1] = PreparedCue(
                        timeRange: CMTimeRange(start: previous.timeRange.start, end: start),
                        text: previous.text
                    )
                } else {
                    result.removeLast()
                }
            }

            result.append(
                PreparedCue(
                    timeRange: CMTimeRange(start: start, end: end),
                    text: text
                )
            )
        }

        guard !result.isEmpty else {
            throw RenderError.emptySubtitles
        }
        return result
    }

    private func videoGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) throws -> (renderSize: CGSize, transform: CGAffineTransform) {
        guard naturalSize.width.isFinite,
              naturalSize.height.isFinite,
              naturalSize.width > 0,
              naturalSize.height > 0 else {
            throw RenderError.invalidRenderSize
        }

        let sourceRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = sourceRect.applying(preferredTransform).standardized
        guard transformedRect.width.isFinite,
              transformedRect.height.isFinite,
              transformedRect.width > 0,
              transformedRect.height > 0 else {
            throw RenderError.invalidRenderSize
        }

        var normalizedTransform = preferredTransform
        normalizedTransform.tx -= transformedRect.minX
        normalizedTransform.ty -= transformedRect.minY

        let renderSize = CGSize(
            width: evenPixelDimension(transformedRect.width),
            height: evenPixelDimension(transformedRect.height)
        )
        return (renderSize, normalizedTransform)
    }

    private func evenPixelDimension(_ value: CGFloat) -> CGFloat {
        max(2, ceil(value / 2) * 2)
    }

    private func makeVideoComposition(
        videoTrack: AVCompositionTrack,
        normalizedTransform: CGAffineTransform,
        renderSize: CGSize,
        frameRate: Float,
        duration: CMTime,
        cues: [PreparedCue],
        style: Style
    ) async throws -> AVMutableVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(normalizedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize

        let framesPerSecond = frameRate.isFinite && frameRate > 0 ? Double(frameRate) : 30
        videoComposition.frameDuration = CMTime(
            seconds: 1 / framesPerSecond,
            preferredTimescale: 60_000
        )

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        // 离屏视频合成的图层坐标不是 UIView 坐标；翻转独立字幕容器可保证文字正向显示。
        let subtitleLayer = CALayer()
        subtitleLayer.frame = parentLayer.bounds
        subtitleLayer.isGeometryFlipped = true
        parentLayer.addSublayer(subtitleLayer)

        for (index, cue) in cues.enumerated() {
            if index.isMultiple(of: 24) {
                try checkCancellation()
                await Task.yield()
            }
            subtitleLayer.addSublayer(
                makeCueLayer(
                    cue: cue,
                    renderSize: renderSize,
                    videoDuration: duration,
                    style: style
                )
            )
        }
        try checkCancellation()

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
        return videoComposition
    }

    private func makeCueLayer(
        cue: PreparedCue,
        renderSize: CGSize,
        videoDuration: CMTime,
        style: Style
    ) -> CALayer {
        let minimumDimension = min(renderSize.width, renderSize.height)
        let maximumTextWidth = renderSize.width * clamped(style.maximumTextWidthRatio, 0.4...0.96)
        let horizontalPadding = minimumDimension * clamped(style.horizontalPaddingRatio, 0.005...0.08)
        let verticalPadding = minimumDimension * clamped(style.verticalPaddingRatio, 0.004...0.05)
        let maximumLines = max(1, min(style.maximumLineCount, 4))

        let font = fittedFont(
            text: cue.text,
            fontName: style.fontName,
            preferredSize: minimumDimension * clamped(style.fontSizeRatio, 0.02...0.12),
            minimumSize: minimumDimension * clamped(style.minimumFontSizeRatio, 0.015...0.08),
            maximumTextWidth: maximumTextWidth - horizontalPadding * 2,
            maximumLines: maximumLines
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.baseWritingDirection = .natural
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = font.pointSize * 0.08

        let attributedText = NSAttributedString(
            string: cue.text,
            attributes: [
                .font: font,
                .foregroundColor: style.textColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        let measuredTextSize = attributedText.boundingRect(
            with: CGSize(
                width: maximumTextWidth - horizontalPadding * 2,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral.size

        let maximumTextHeight = font.lineHeight * CGFloat(maximumLines)
            + paragraphStyle.lineSpacing * CGFloat(max(0, maximumLines - 1))
        let textHeight = min(measuredTextSize.height, maximumTextHeight)
        let boxWidth = min(
            maximumTextWidth,
            max(measuredTextSize.width + horizontalPadding * 2, font.pointSize * 3)
        )
        let boxHeight = textHeight + verticalPadding * 2
        let bottomMargin = renderSize.height * clamped(style.bottomMarginRatio, 0.02...0.25)
        let boxFrame = CGRect(
            x: (renderSize.width - boxWidth) / 2,
            y: max(0, renderSize.height - bottomMargin - boxHeight),
            width: boxWidth,
            height: boxHeight
        ).integral

        let containerLayer = CALayer()
        containerLayer.frame = boxFrame
        containerLayer.backgroundColor = style.backgroundColor.cgColor
        containerLayer.cornerRadius = minimumDimension * clamped(style.cornerRadiusRatio, 0...0.05)
        containerLayer.masksToBounds = true
        containerLayer.opacity = 0

        let textLayer = CATextLayer()
        textLayer.frame = CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: boxFrame.width - horizontalPadding * 2,
            height: boxFrame.height - verticalPadding * 2
        ).integral
        textLayer.string = attributedText
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.truncationMode = .end
        textLayer.contentsScale = 1
        containerLayer.addSublayer(textLayer)

        addVisibilityAnimation(
            to: containerLayer,
            timeRange: cue.timeRange,
            videoDuration: videoDuration
        )
        return containerLayer
    }

    private func fittedFont(
        text: String,
        fontName: String?,
        preferredSize: CGFloat,
        minimumSize: CGFloat,
        maximumTextWidth: CGFloat,
        maximumLines: Int
    ) -> UIFont {
        var size = max(preferredSize, minimumSize)
        while size > minimumSize {
            let font = makeFont(name: fontName, size: size)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            if measured.height <= font.lineHeight * CGFloat(maximumLines) * 1.15 {
                return font
            }
            size -= max(1, preferredSize * 0.04)
        }
        return makeFont(name: fontName, size: minimumSize)
    }

    private func makeFont(name: String?, size: CGFloat) -> UIFont {
        if let name,
           let font = UIFont(name: name, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func addVisibilityAnimation(
        to layer: CALayer,
        timeRange: CMTimeRange,
        videoDuration: CMTime
    ) {
        let durationSeconds = videoDuration.seconds
        let start = clamped(timeRange.start.seconds / durationSeconds, 0...1)
        let end = clamped(CMTimeRangeGetEnd(timeRange).seconds / durationSeconds, 0...1)

        if start <= 0, end >= 1 {
            layer.opacity = 1
            return
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if start <= 0 {
            animation.values = [1, 0]
            animation.keyTimes = [0, NSNumber(value: end)]
        } else if end >= 1 {
            animation.values = [0, 1]
            animation.keyTimes = [0, NSNumber(value: start)]
        } else {
            animation.values = [0, 1, 0]
            animation.keyTimes = [0, NSNumber(value: start), NSNumber(value: end)]
        }
        animation.calculationMode = .discrete
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = durationSeconds
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "subtitleVisibility")
    }

    private func clamped<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func startProgressReporting(
        exportSession: AVAssetExportSession,
        callback: @escaping (Double) -> Void
    ) {
        progressTask?.cancel()
        guard #available(iOS 18.0, *) else { return }
        let states = exportSession.states(updateInterval: 0.12)
        progressTask = Task { @MainActor in
            var lastReportedProgress = 0.0
            for await state in states {
                guard !Task.isCancelled else { return }
                switch state {
                case .pending, .waiting:
                    break
                case let .exporting(progress):
                    let rawProgress = progress.fractionCompleted
                    guard rawProgress.isFinite else { continue }
                    let currentProgress = min(
                        0.999,
                        max(0, rawProgress)
                    )
                    if currentProgress > lastReportedProgress {
                        lastReportedProgress = currentProgress
                        callback(currentProgress)
                    }
                @unknown default:
                    return
                }
            }
        }
    }

    private func validateExportedFile(
        at outputURL: URL,
        expectedDuration: CMTime,
        expectedVideoTimeRange: CMTimeRange,
        expectedAudioTimeRange: CMTimeRange?,
        frameDuration: CMTime
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
              let outputVideoTrack = outputVideoTracks.first else {
            throw RenderError.exportedVideoIsInvalid
        }

        let outputVideoTimeRange = try await outputVideoTrack.load(.timeRange)
        let outputAudioTimeRange: CMTimeRange?
        if let outputAudioTrack = outputAudioTracks.first {
            outputAudioTimeRange = try await outputAudioTrack.load(.timeRange)
        } else {
            outputAudioTimeRange = nil
        }

        guard expectedVideoTimeRange.isValid,
              expectedVideoTimeRange.start.isNumeric,
              expectedVideoTimeRange.duration.isNumeric,
              outputVideoTimeRange.isValid,
              outputVideoTimeRange.start.isNumeric,
              outputVideoTimeRange.duration.isNumeric else {
            throw RenderError.exportedVideoIsInvalid
        }

        let frameSeconds = frameDuration.isValid
            && frameDuration.isNumeric
            && frameDuration.seconds > 0
            ? frameDuration.seconds
            : 1 / 30
        var timingValues = [
            expectedDuration,
            outputDuration,
            expectedVideoTimeRange.duration,
            outputVideoTimeRange.duration,
            frameDuration,
        ]
        if let expectedAudioTimeRange {
            timingValues.append(expectedAudioTimeRange.duration)
        }
        if let outputAudioTimeRange {
            timingValues.append(outputAudioTimeRange.duration)
        }
        let timingTick = maximumTimingTick(timingValues)
        let videoBoundaryTolerance = frameSeconds + timingTick * 2
        // AAC-LC 一包通常是 1024 samples，即 44.1/48kHz 下约 23/21ms。
        // 对齐校验允许一帧或一个音频包的量化误差，但不会放行完整的 AAC priming。
        let audioBoundaryTolerance = max(frameSeconds, 0.025) + timingTick * 2
        let durationTolerance = expectedAudioTimeRange == nil
            ? videoBoundaryTolerance
            : audioBoundaryTolerance

        guard approximatelyEqual(
            outputDuration,
            expectedDuration,
            tolerance: durationTolerance
        ) else {
            throw RenderError.exportedDurationMismatch
        }
        guard approximatelyEqual(
            outputVideoTimeRange.start,
            expectedVideoTimeRange.start,
            tolerance: videoBoundaryTolerance
        ), approximatelyEqual(
            CMTimeRangeGetEnd(outputVideoTimeRange),
            CMTimeRangeGetEnd(expectedVideoTimeRange),
            tolerance: videoBoundaryTolerance
        ) else {
            throw RenderError.exportedVideoTimingMismatch
        }

        if let expectedAudioTimeRange {
            guard let outputAudioTimeRange else {
                throw RenderError.audioTrackWasNotPreserved
            }
            guard expectedAudioTimeRange.isValid,
                  expectedAudioTimeRange.start.isNumeric,
                  expectedAudioTimeRange.duration.isNumeric,
                  outputAudioTimeRange.isValid,
                  outputAudioTimeRange.start.isNumeric,
                  outputAudioTimeRange.duration.isNumeric else {
                throw RenderError.exportedAudioTimingMismatch
            }

            let expectedStartDelta = CMTimeSubtract(
                expectedAudioTimeRange.start,
                expectedVideoTimeRange.start
            )
            let outputStartDelta = CMTimeSubtract(
                outputAudioTimeRange.start,
                outputVideoTimeRange.start
            )
            let expectedEndDelta = CMTimeSubtract(
                CMTimeRangeGetEnd(expectedAudioTimeRange),
                CMTimeRangeGetEnd(expectedVideoTimeRange)
            )
            let outputEndDelta = CMTimeSubtract(
                CMTimeRangeGetEnd(outputAudioTimeRange),
                CMTimeRangeGetEnd(outputVideoTimeRange)
            )
            guard approximatelyEqual(
                outputStartDelta,
                expectedStartDelta,
                tolerance: audioBoundaryTolerance
            ), approximatelyEqual(
                outputEndDelta,
                expectedEndDelta,
                tolerance: audioBoundaryTolerance
            ) else {
                throw RenderError.exportedAudioTimingMismatch
            }
        }
    }

    private func maximumTimingTick(_ times: [CMTime]) -> TimeInterval {
        times.reduce(0) { result, time in
            guard time.value != 0,
                  time.timescale > 0 else { return result }
            return max(result, 1 / Double(time.timescale))
        }
    }

    private func approximatelyEqual(
        _ lhs: CMTime,
        _ rhs: CMTime,
        tolerance: TimeInterval
    ) -> Bool {
        guard lhs.isValid,
              rhs.isValid,
              lhs.isNumeric,
              rhs.isNumeric else {
            return false
        }
        return abs(lhs.seconds - rhs.seconds) <= tolerance
    }

}
