import AVFoundation
import Combine
import Photos
import SwiftUI
import UIKit

/// App 内相机采集控制器。`AVCaptureMovieFileOutput` 只接收相机和麦克风输入，
/// 因此叠加在预览上方的提词 UI 不会被录入成片。
@MainActor
final class CameraCaptureController: NSObject, ObservableObject {

    enum SubtitleGenerationState: Equatable {
        case notStarted
        case transcribing(progress: Double)
        case rendering(progress: Double)
        case saving
        case completed
        case failed(message: String)

        var isProcessing: Bool {
            switch self {
            case .transcribing, .rendering, .saving:
                return true
            case .notStarted, .completed, .failed:
                return false
            }
        }

        /// 统一映射为完整流水线进度，避免从识别切到渲染时进度回退。
        var overallProgress: Double {
            switch self {
            case .notStarted, .failed:
                return 0
            case .transcribing(let progress):
                return min(max(progress, 0), 1) * 0.6
            case .rendering(let progress):
                return 0.6 + min(max(progress, 0), 1) * 0.35
            case .saving:
                return 0.98
            case .completed:
                return 1
            }
        }
    }

    struct RecordedClip: Identifiable {
        let assetIdentifier: String
        let fileURL: URL
        let thumbnail: UIImage?
        var subtitleCues: [SubtitleCue] = []
        var subtitleGenerationState: SubtitleGenerationState = .notStarted
        var subtitledAssetIdentifier: String?
        var subtitledFileURL: URL?

        var id: String { assetIdentifier }

        var previewURL: URL {
            subtitledFileURL ?? fileURL
        }
    }

    // MARK: - Published state

    @Published private(set) var cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var photoPermissionStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @Published private(set) var isRequestingPermissions = false
    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isSaving = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front
    @Published private(set) var activeVideoDevice: AVCaptureDevice?
    @Published private(set) var errorMessage: String?
    @Published private(set) var saveConfirmation: String?
    @Published private(set) var lastSavedAssetIdentifier: String?
    @Published private(set) var hasPendingSave = false
    @Published private(set) var savedClips: [RecordedClip] = []
    @Published private(set) var deletingClipIdentifier: String?
    @Published private(set) var subtitleProcessingClipIdentifier: String?

    var isGeneratingSubtitles: Bool {
        subtitleProcessingClipIdentifier != nil
    }

    /// 供 `CameraPreviewView(session:device:)` 显示实时画面。
    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.teleprompter.camera.capture-session", qos: .userInitiated)
    private let temporaryDirectory: URL

    // 以下属性只在 sessionQueue 上读写。
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configuredOnQueue = false
    private var preferredPositionOnQueue: AVCaptureDevice.Position = .front
    private var recordingStartPending = false
    private var stopRecordingWhenStarted = false
    private var stopSessionAfterRecording = false
    private var stopSessionAfterRecordingGeneration: Int?
    private var activeRecordingURL: URL?

    // 以下属性只在主线程读写。
    private var wantsSessionRunning = false
    private var lifecycleGeneration = 0
    private var permissionTask: Task<Void, Never>?
    private var isStartingRecording = false
    private var pendingSaveURL: URL?
    private var photoDeletedClipIdentifiers: Set<String> = []
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var notificationTokens: [NSObjectProtocol] = []
    private var subtitleGenerationTask: Task<Void, Never>?

    override init() {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeleprompterCamera", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        super.init()
        installNotifications()
        removeExpiredTemporaryRecordings()
    }

    deinit {
        permissionTask?.cancel()
        subtitleGenerationTask?.cancel()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)

        let session = session
        let movieOutput = movieOutput
        let sessionQueue = sessionQueue
        let temporaryDirectory = temporaryDirectory
        let hasPendingSave = pendingSaveURL != nil
        sessionQueue.async {
            let wasRecording = movieOutput.isRecording
            if wasRecording {
                movieOutput.stopRecording()
            }
            if session.isRunning {
                session.stopRunning()
            }
            if !wasRecording, !hasPendingSave {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
    }

    // MARK: - Permissions and lifecycle

    /// 请求相机、麦克风权限并启动采集。重复调用不会重复配置 Session。
    func requestPermissionsAndStart() {
        wantsSessionRunning = true
        lifecycleGeneration += 1

        guard permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let granted = await self.requestCapturePermissions()
            self.permissionTask = nil
            guard granted,
                  self.wantsSessionRunning else { return }
            self.configureAndStartSession(generation: self.lifecycleGeneration)
        }
    }

    /// 可由权限说明页单独调用；照片权限在保存录像时按需申请。
    @discardableResult
    func requestCapturePermissions() async -> Bool {
        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        refreshPermissionStatuses()
        guard cameraPermissionStatus == .authorized else {
            errorMessage = permissionMessage(for: cameraPermissionStatus, mediaName: "相机")
            return false
        }
        guard microphonePermissionStatus == .authorized else {
            errorMessage = permissionMessage(for: microphonePermissionStatus, mediaName: "麦克风")
            return false
        }
        return true
    }

    /// 停止录像后再停止 Session；这样离开拍摄页时已经拍到的内容仍会正常保存。
    func stopSession() {
        wantsSessionRunning = false
        lifecycleGeneration += 1
        let generation = lifecycleGeneration

        let session = session
        let movieOutput = movieOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if movieOutput.isRecording {
                self.stopSessionAfterRecording = true
                self.stopSessionAfterRecordingGeneration = generation
                movieOutput.stopRecording()
            } else if self.recordingStartPending {
                self.stopSessionAfterRecording = true
                self.stopSessionAfterRecordingGeneration = generation
                self.stopRecordingWhenStarted = true
            } else {
                if session.isRunning {
                    session.stopRunning()
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          !self.wantsSessionRunning else { return }
                    self.isRunning = false
                }
            }
        }
    }

    func refreshPermissionStatuses() {
        cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        photoPermissionStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording || isStartingRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        errorMessage = nil
        saveConfirmation = nil
        lastSavedAssetIdentifier = nil

        guard pendingSaveURL == nil else {
            errorMessage = "上一个视频尚未保存，请先重试保存"
            return
        }
        guard isConfigured, isRunning else {
            errorMessage = "相机尚未准备完成"
            return
        }
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true

        let rotationAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
        let position = cameraPosition
        let session = session
        let movieOutput = movieOutput
        let temporaryDirectory = temporaryDirectory

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configuredOnQueue,
                  session.isRunning,
                  !movieOutput.isRecording,
                  !self.recordingStartPending else {
                Task { @MainActor [weak self] in
                    self?.isStartingRecording = false
                }
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                let outputURL = temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try? FileManager.default.removeItem(at: outputURL)

                guard let connection = movieOutput.connection(with: .video) else {
                    throw CameraCaptureFailure("无法建立录像视频连接")
                }
                if connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = position == .front
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }

                self.recordingStartPending = true
                self.stopRecordingWhenStarted = false
                self.stopSessionAfterRecording = false
                self.stopSessionAfterRecordingGeneration = nil
                self.activeRecordingURL = outputURL
                movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.isStartingRecording = false
                    self?.isRecording = false
                }
            }
        }
    }

    func stopRecording() {
        let movieOutput = movieOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            } else if self.recordingStartPending {
                self.stopRecordingWhenStarted = true
            }
        }
    }

    // MARK: - Camera switching

    func switchCamera() {
        errorMessage = nil
        let session = session
        let movieOutput = movieOutput

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !movieOutput.isRecording, !self.recordingStartPending else {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "录像过程中不能切换摄像头"
                }
                return
            }

            let currentPosition = self.videoInput?.device.position ?? self.preferredPositionOnQueue
            let targetPosition: AVCaptureDevice.Position = currentPosition == .front ? .back : .front
            guard let device = Self.cameraDevice(position: targetPosition) else {
                Task { @MainActor [weak self] in
                    self?.errorMessage = targetPosition == .front ? "前置摄像头不可用" : "后置摄像头不可用"
                }
                return
            }

            guard self.configuredOnQueue, let oldInput = self.videoInput else {
                self.preferredPositionOnQueue = targetPosition
                Task { @MainActor [weak self] in
                    self?.cameraPosition = targetPosition
                }
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.removeInput(oldInput)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    self.videoInput = newInput
                    self.preferredPositionOnQueue = targetPosition
                    session.commitConfiguration()
                    Task { @MainActor [weak self] in
                        self?.didActivateVideoDevice(device)
                    }
                } else {
                    if session.canAddInput(oldInput) {
                        session.addInput(oldInput)
                    }
                    session.commitConfiguration()
                    throw CameraCaptureFailure("无法切换摄像头")
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearMessages() {
        errorMessage = nil
        saveConfirmation = nil
    }

    // MARK: - Session configuration

    private func configureAndStartSession(generation: Int) {
        errorMessage = nil
        let session = session
        let movieOutput = movieOutput

        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                let device: AVCaptureDevice
                if self.configuredOnQueue, let configuredDevice = self.videoInput?.device {
                    device = configuredDevice
                } else {
                    device = try self.configureSession(session: session, movieOutput: movieOutput)
                }

                if !session.isRunning {
                    session.startRunning()
                }
                let running = session.isRunning
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isConfigured = true
                    self.didActivateVideoDevice(device)
                    if generation == self.lifecycleGeneration, self.wantsSessionRunning {
                        self.isRunning = running
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isConfigured = false
                    self?.isRunning = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func configureSession(
        session: AVCaptureSession,
        movieOutput: AVCaptureMovieFileOutput
    ) throws -> AVCaptureDevice {
        guard let camera = Self.cameraDevice(position: preferredPositionOnQueue)
            ?? Self.cameraDevice(position: .back) else {
            throw CameraCaptureFailure("摄像头不可用")
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw CameraCaptureFailure("麦克风不可用")
        }

        let newVideoInput = try AVCaptureDeviceInput(device: camera)
        let newAudioInput = try AVCaptureDeviceInput(device: microphone)

        session.beginConfiguration()
        do {
            session.sessionPreset = .high
            guard session.canAddInput(newVideoInput) else {
                throw CameraCaptureFailure("无法添加摄像头输入")
            }
            session.addInput(newVideoInput)

            guard session.canAddInput(newAudioInput) else {
                throw CameraCaptureFailure("无法添加麦克风输入")
            }
            session.addInput(newAudioInput)

            guard session.canAddOutput(movieOutput) else {
                throw CameraCaptureFailure("无法添加录像输出")
            }
            session.addOutput(movieOutput)
            session.commitConfiguration()

            videoInput = newVideoInput
            audioInput = newAudioInput
            preferredPositionOnQueue = camera.position
            configuredOnQueue = true
            return camera
        } catch {
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            videoInput = nil
            audioInput = nil
            configuredOnQueue = false
            throw error
        }
    }

    private static func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if position == .front {
            deviceTypes = [.builtInWideAngleCamera, .builtInTrueDepthCamera]
        } else {
            deviceTypes = [
                .builtInWideAngleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInTripleCamera,
            ]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        ).devices.first
    }

    private func didActivateVideoDevice(_ device: AVCaptureDevice) {
        cameraPosition = device.position
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        activeVideoDevice = device
    }

    // MARK: - Saving

    private func recordingDidFinish(at outputURL: URL, error: Error?) {
        isStartingRecording = false
        isRecording = false
        let wasSuccessful = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)

        let session = session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordingStartPending = false
            self.stopRecordingWhenStarted = false
            self.activeRecordingURL = nil
            let shouldResolveSessionState = self.stopSessionAfterRecording
            let requestedGeneration = self.stopSessionAfterRecordingGeneration
            self.stopSessionAfterRecording = false
            self.stopSessionAfterRecordingGeneration = nil
            if shouldResolveSessionState {
                Task { @MainActor [weak self] in
                    self?.resolveSessionAfterRecordingStop(
                        session: session,
                        requestedGeneration: requestedGeneration
                    )
                }
            }
        }

        guard wasSuccessful else {
            errorMessage = error?.localizedDescription ?? "录像失败"
            removeTemporaryRecording(at: outputURL)
            return
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            errorMessage = "录像文件不存在"
            return
        }

        pendingSaveURL = outputURL
        hasPendingSave = true
        isSaving = true
        Task { [weak self] in
            await self?.saveRecordingToPhotoLibrary(at: outputURL)
        }
    }

    func retryPendingSave() {
        guard !isSaving else { return }
        guard let pendingSaveURL else {
            errorMessage = "没有待保存的视频"
            return
        }
        guard FileManager.default.fileExists(atPath: pendingSaveURL.path) else {
            self.pendingSaveURL = nil
            hasPendingSave = false
            errorMessage = "待保存的视频文件不存在"
            return
        }

        errorMessage = nil
        saveConfirmation = nil
        isSaving = true
        Task { [weak self] in
            await self?.saveRecordingToPhotoLibrary(at: pendingSaveURL)
        }
    }

    func discardPendingSave() {
        guard !isSaving, let pendingSaveURL else { return }
        self.pendingSaveURL = nil
        hasPendingSave = false
        errorMessage = nil
        saveConfirmation = nil
        removeTemporaryRecording(at: pendingSaveURL)
    }

    func generateSubtitledVideo(for clip: RecordedClip) {
        guard !isSaving,
              deletingClipIdentifier == nil else {
            errorMessage = "请等待当前视频操作完成"
            return
        }
        guard subtitleProcessingClipIdentifier == nil else {
            errorMessage = "请等待当前字幕视频生成完成"
            return
        }
        guard let currentClip = savedClips.first(where: { $0.id == clip.id }) else {
            errorMessage = "找不到需要生成字幕的视频"
            return
        }
        guard currentClip.subtitleGenerationState != .completed else { return }
        guard FileManager.default.fileExists(atPath: currentClip.fileURL.path) else {
            updateSavedClip(identifier: currentClip.id) {
                $0.subtitleGenerationState = .failed(message: "原视频临时文件已失效，请重新录制")
            }
            return
        }

        errorMessage = nil
        saveConfirmation = nil
        subtitleProcessingClipIdentifier = currentClip.id
        updateSavedClip(identifier: currentClip.id) {
            $0.subtitleCues = []
            $0.subtitleGenerationState = .transcribing(progress: 0)
        }

        subtitleGenerationTask = Task { [weak self] in
            guard let self else { return }
            await self.performSubtitleGeneration(
                clipIdentifier: currentClip.id,
                sourceURL: currentClip.fileURL
            )
        }
    }

    func cancelSubtitleGeneration(for clip: RecordedClip) {
        guard subtitleProcessingClipIdentifier == clip.id,
              let currentClip = savedClips.first(where: { $0.id == clip.id }) else { return }
        guard currentClip.subtitleGenerationState != .saving else { return }
        cancelSubtitleGeneration()
    }

    func cancelSubtitleGeneration() {
        guard let identifier = subtitleProcessingClipIdentifier,
              let currentClip = savedClips.first(where: { $0.id == identifier }),
              currentClip.subtitleGenerationState != .saving else { return }
        subtitleGenerationTask?.cancel()
        HardSubtitleRenderer.shared.cancel()
    }

    private func performSubtitleGeneration(
        clipIdentifier: String,
        sourceURL: URL
    ) async {
        var renderedURL: URL?
        defer {
            if subtitleProcessingClipIdentifier == clipIdentifier {
                subtitleProcessingClipIdentifier = nil
                subtitleGenerationTask = nil
            }
        }

        do {
            let cues = try await LocalSubtitleTranscriber.shared.transcribeVideo(
                at: sourceURL,
                locale: Locale(identifier: "zh-CN")
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.subtitleProcessingClipIdentifier == clipIdentifier else { return }
                    self.updateSavedClip(identifier: clipIdentifier) {
                        guard case .transcribing = $0.subtitleGenerationState else { return }
                        $0.subtitleGenerationState = .transcribing(
                            progress: progress.fractionCompleted
                        )
                    }
                }
            }

            try Task.checkCancellation()
            guard savedClips.contains(where: { $0.id == clipIdentifier }) else {
                throw CancellationError()
            }
            updateSavedClip(identifier: clipIdentifier) {
                $0.subtitleCues = cues
                $0.subtitleGenerationState = .rendering(progress: 0)
            }

            let destinationURL = temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-subtitled")
                .appendingPathExtension("mov")
            renderedURL = try await HardSubtitleRenderer.shared.render(
                videoURL: sourceURL,
                cues: cues,
                outputURL: destinationURL
            ) { [weak self] progress in
                guard let self,
                      self.subtitleProcessingClipIdentifier == clipIdentifier else { return }
                self.updateSavedClip(identifier: clipIdentifier) {
                    guard case .rendering = $0.subtitleGenerationState else { return }
                    $0.subtitleGenerationState = .rendering(progress: progress)
                }
            }

            try Task.checkCancellation()
            updateSavedClip(identifier: clipIdentifier) {
                $0.subtitleGenerationState = .saving
            }
            let subtitledAssetIdentifier = try await saveSubtitledVideoToPhotoLibrary(
                at: destinationURL
            )

            updateSavedClip(identifier: clipIdentifier) {
                $0.subtitledAssetIdentifier = subtitledAssetIdentifier
                $0.subtitledFileURL = destinationURL
                $0.subtitleGenerationState = .completed
            }
        } catch is CancellationError {
            if let renderedURL {
                try? FileManager.default.removeItem(at: renderedURL)
            }
            updateSavedClip(identifier: clipIdentifier) {
                $0.subtitleCues = []
                $0.subtitleGenerationState = .notStarted
            }
        } catch {
            if let renderedURL {
                try? FileManager.default.removeItem(at: renderedURL)
            }
            updateSavedClip(identifier: clipIdentifier) {
                $0.subtitleGenerationState = .failed(message: error.localizedDescription)
            }
        }
    }

    private func saveSubtitledVideoToPhotoLibrary(at outputURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CameraCaptureFailure("字幕版视频文件不存在")
        }

        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            photoPermissionStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            photoPermissionStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        }
        guard photoPermissionStatus == .authorized || photoPermissionStatus == .limited else {
            throw CameraCaptureFailure(permissionMessage(for: photoPermissionStatus))
        }

        let identifierBox = SavedAssetIdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            identifierBox.value = PHAssetChangeRequest
                .creationRequestForAssetFromVideo(atFileURL: outputURL)?
                .placeholderForCreatedAsset?
                .localIdentifier
        }
        guard let identifier = identifierBox.value else {
            throw CameraCaptureFailure("系统未创建字幕版照片资源")
        }
        return identifier
    }

    private func updateSavedClip(
        identifier: String,
        mutation: (inout RecordedClip) -> Void
    ) {
        guard let index = savedClips.firstIndex(where: { $0.id == identifier }) else { return }
        var clip = savedClips[index]
        mutation(&clip)
        savedClips[index] = clip
    }

    func deleteSavedClip(_ clip: RecordedClip) {
        guard !isSaving,
              deletingClipIdentifier == nil,
              let currentClip = savedClips.first(where: { $0.id == clip.id }),
              !currentClip.subtitleGenerationState.isProcessing else { return }

        errorMessage = nil
        saveConfirmation = nil
        deletingClipIdentifier = currentClip.id
        Task { [weak self] in
            await self?.deleteSavedClipFromPhotoLibrary(currentClip)
        }
    }

    private func saveRecordingToPhotoLibrary(at outputURL: URL) async {
        defer {
            isSaving = false
        }

        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            photoPermissionStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            photoPermissionStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        }

        guard photoPermissionStatus == .authorized || photoPermissionStatus == .limited else {
            errorMessage = permissionMessage(for: photoPermissionStatus)
            return
        }

        let identifierBox = SavedAssetIdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                identifierBox.value = PHAssetChangeRequest
                    .creationRequestForAssetFromVideo(atFileURL: outputURL)?
                    .placeholderForCreatedAsset?
                    .localIdentifier
            }
            guard let savedAssetIdentifier = identifierBox.value else {
                errorMessage = "保存视频失败：系统未创建照片资源"
                return
            }
            let thumbnail = await makeThumbnail(for: outputURL)
            lastSavedAssetIdentifier = savedAssetIdentifier
            savedClips.append(
                RecordedClip(
                    assetIdentifier: savedAssetIdentifier,
                    fileURL: outputURL,
                    thumbnail: thumbnail
                )
            )
            if pendingSaveURL == outputURL {
                pendingSaveURL = nil
                hasPendingSave = false
            }
        } catch {
            errorMessage = "保存视频失败：\(error.localizedDescription)"
        }
    }

    private func makeThumbnail(for videoURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        let requestedTimes = [
            CMTime(seconds: 0.1, preferredTimescale: 600),
            CMTime.zero,
        ]
        for time in requestedTimes {
            do {
                let result = try await generator.image(at: time)
                return UIImage(cgImage: result.image)
            } catch {
                continue
            }
        }
        return nil
    }

    private func deleteSavedClipFromPhotoLibrary(_ clip: RecordedClip) async {
        defer {
            deletingClipIdentifier = nil
        }

        if photoDeletedClipIdentifiers.contains(clip.id) {
            await finishDeletingSavedClip(clip)
            return
        }

        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }

        guard status == .authorized || status == .limited else {
            errorMessage = photoDeletionPermissionMessage(for: status)
            return
        }

        let assetIdentifiers = [clip.assetIdentifier, clip.subtitledAssetIdentifier]
            .compactMap { $0 }
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIdentifiers,
            options: nil
        )
        guard assets.count > 0 else {
            if status == .limited {
                errorMessage = "无法访问该视频，请前往系统设置允许访问全部照片后重试"
                return
            }
            photoDeletedClipIdentifiers.insert(clip.id)
            await finishDeletingSavedClip(clip)
            return
        }
        if status == .limited, assets.count < assetIdentifiers.count {
            errorMessage = "无法访问这段录像的全部版本，请前往系统设置允许访问全部照片后重试"
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            photoDeletedClipIdentifiers.insert(clip.id)
            await finishDeletingSavedClip(clip)
        } catch {
            errorMessage = "删除视频失败：\(error.localizedDescription)"
        }
    }

    private func finishDeletingSavedClip(_ clip: RecordedClip) async {
        var localFilesRemoved = await removeTemporaryRecordingAndReport(at: clip.fileURL)
        if let subtitledFileURL = clip.subtitledFileURL {
            localFilesRemoved = await removeTemporaryRecordingAndReport(at: subtitledFileURL)
                && localFilesRemoved
        }
        guard localFilesRemoved else {
            errorMessage = "系统相册视频已删除，但本地预览文件清理失败，请重试"
            return
        }

        savedClips.removeAll { $0.id == clip.id }
        if lastSavedAssetIdentifier == clip.assetIdentifier {
            lastSavedAssetIdentifier = savedClips.last?.assetIdentifier
        }
        photoDeletedClipIdentifiers.remove(clip.id)
        saveConfirmation = "视频已删除"
    }

    private func removeTemporaryRecordingAndReport(at url: URL) async -> Bool {
        let temporaryDirectory = temporaryDirectory
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    if let items = try? FileManager.default.contentsOfDirectory(
                        at: temporaryDirectory,
                        includingPropertiesForKeys: nil
                    ), items.isEmpty {
                        try? FileManager.default.removeItem(at: temporaryDirectory)
                    }
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func removeTemporaryRecording(at url: URL) {
        let temporaryDirectory = temporaryDirectory
        sessionQueue.async {
            try? FileManager.default.removeItem(at: url)
            if let items = try? FileManager.default.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil
            ), items.isEmpty {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
    }

    private func removeExpiredTemporaryRecordings() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeleprompterCamera", isDirectory: true)
        sessionQueue.async {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }

            let expirationDate = Date().addingTimeInterval(-24 * 60 * 60)
            for directory in directories where directory != self.temporaryDirectory {
                let values = try? directory.resourceValues(forKeys: keys)
                guard values?.isDirectory == true,
                      let modifiedAt = values?.contentModificationDate,
                      modifiedAt < expirationDate else { continue }
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    // MARK: - Notifications

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRuntimeError(notification)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                if let rawValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
                   let reason = AVCaptureSession.InterruptionReason(rawValue: rawValue) {
                    self?.errorMessage = "相机采集已中断（\(reason.rawValue)）"
                } else {
                    self?.errorMessage = "相机采集已中断"
                }
            }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wantsSessionRunning else { return }
                self.configureAndStartSession(generation: self.lifecycleGeneration)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspendSessionForBackground()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissionStatuses()
                guard self.wantsSessionRunning,
                      self.permissionTask == nil else { return }

                guard self.cameraPermissionStatus == .authorized else {
                    self.errorMessage = self.permissionMessage(
                        for: self.cameraPermissionStatus,
                        mediaName: "相机"
                    )
                    return
                }
                guard self.microphonePermissionStatus == .authorized else {
                    self.errorMessage = self.permissionMessage(
                        for: self.microphonePermissionStatus,
                        mediaName: "麦克风"
                    )
                    return
                }

                self.lifecycleGeneration += 1
                self.configureAndStartSession(generation: self.lifecycleGeneration)

                if self.hasPendingSave, !self.isSaving {
                    if self.photoPermissionStatus == .authorized
                        || self.photoPermissionStatus == .limited {
                        self.errorMessage = "视频尚未保存，请点击“重试保存”"
                    } else {
                        self.errorMessage = self.permissionMessage(for: self.photoPermissionStatus)
                    }
                }
            }
        })
    }

    /// App 进入后台时暂停采集，但保留拍摄页希望继续使用相机的状态。
    /// 回到前台后自动恢复；真正离开拍摄页仍调用 stopSession()。
    private func suspendSessionForBackground() {
        let generation = lifecycleGeneration
        let session = session
        let movieOutput = movieOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if movieOutput.isRecording {
                self.stopSessionAfterRecording = true
                self.stopSessionAfterRecordingGeneration = generation
                movieOutput.stopRecording()
            } else if self.recordingStartPending {
                self.stopSessionAfterRecording = true
                self.stopSessionAfterRecordingGeneration = generation
                self.stopRecordingWhenStarted = true
            } else {
                if session.isRunning {
                    session.stopRunning()
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.lifecycleGeneration == generation else { return }
                    self.isRunning = false
                }
            }
        }
    }

    private func resolveSessionAfterRecordingStop(
        session: AVCaptureSession,
        requestedGeneration: Int?
    ) {
        if wantsSessionRunning, requestedGeneration != lifecycleGeneration {
            configureAndStartSession(generation: lifecycleGeneration)
            return
        }

        let generation = lifecycleGeneration
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.lifecycleGeneration == generation else { return }
                self.isRunning = false
            }
        }
    }

    private func handleRuntimeError(_ notification: Notification) {
        isRunning = false
        let avError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        errorMessage = avError.map { "相机运行错误：\($0.localizedDescription)" } ?? "相机运行错误"
        if avError?.code == .mediaServicesWereReset, wantsSessionRunning {
            configureAndStartSession(generation: lifecycleGeneration)
        }
    }

    private func permissionMessage(for status: AVAuthorizationStatus, mediaName: String) -> String {
        switch status {
        case .denied:
            return "没有\(mediaName)权限，请前往系统设置允许访问"
        case .restricted:
            return "当前设备限制了\(mediaName)访问"
        default:
            return "无法获得\(mediaName)权限"
        }
    }

    private func permissionMessage(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "没有照片添加权限，请前往系统设置允许添加照片"
        case .restricted:
            return "当前设备限制了照片访问"
        default:
            return "无法获得照片添加权限"
        }
    }

    private func photoDeletionPermissionMessage(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "没有照片访问权限，请前往系统设置允许访问照片后重试"
        case .restricted:
            return "当前设备限制了照片访问，无法删除视频"
        default:
            return "无法获得照片访问权限，不能删除视频"
        }
    }
}

extension CameraCaptureController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isStartingRecording = false
            self.isRecording = true
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.recordingStartPending = false
                if self.stopRecordingWhenStarted, self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                }
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.recordingDidFinish(at: outputFileURL, error: error)
        }
    }
}

/// SwiftUI 相机预览。提词浮层应在 SwiftUI 中叠放于此视图上方，
/// 它不会进入 `AVCaptureMovieFileOutput` 输出的视频。
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    var onDismantle: (() -> Void)?

    init(
        session: AVCaptureSession,
        device: AVCaptureDevice?,
        onDismantle: (() -> Void)? = nil
    ) {
        self.session = session
        self.device = device
        self.onDismantle = onDismantle
    }

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.onDismantle = onDismantle
        view.setSession(session)
        view.setVideoDevice(device)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.onDismantle = onDismantle
        uiView.setSession(session)
        uiView.setVideoDevice(device)
    }

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) {
        uiView.onDismantle?()
        uiView.prepareForRemoval()
    }

    func makeCoordinator() -> Void {
        ()
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onDismantle: (() -> Void)?

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var sessionStartObserver: NSObjectProtocol?
    private var currentDeviceID: String?
    private var videoDevice: AVCaptureDevice?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        previewLayer.videoGravity = .resizeAspectFill
    }

    deinit {
        if let sessionStartObserver {
            NotificationCenter.default.removeObserver(sessionStartObserver)
        }
    }

    func setSession(_ session: AVCaptureSession) {
        guard previewLayer.session !== session else {
            applyPreviewRotation()
            return
        }
        if let sessionStartObserver {
            NotificationCenter.default.removeObserver(sessionStartObserver)
        }
        previewLayer.session = session
        sessionStartObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.applyPreviewRotation()
        }
        applyPreviewRotation()
    }

    func setVideoDevice(_ device: AVCaptureDevice?) {
        guard currentDeviceID != device?.uniqueID else {
            applyPreviewRotation()
            return
        }

        previewRotationObservation = nil
        rotationCoordinator = nil
        videoDevice = device
        currentDeviceID = device?.uniqueID

        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )
        rotationCoordinator = coordinator
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] observedCoordinator, _ in
            guard let self,
                  self.rotationCoordinator === observedCoordinator else { return }
            self.applyPreviewRotation()
        }
        applyPreviewRotation()

        let deviceID = device.uniqueID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentDeviceID == deviceID else { return }
            self.applyPreviewRotation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPreviewRotation()
    }

    func prepareForRemoval() {
        if let sessionStartObserver {
            NotificationCenter.default.removeObserver(sessionStartObserver)
            self.sessionStartObserver = nil
        }
        previewRotationObservation = nil
        rotationCoordinator = nil
        videoDevice = nil
        currentDeviceID = nil
        previewLayer.session = nil
    }

    private func applyPreviewRotation() {
        guard let connection = previewLayer.connection,
              let rotationCoordinator,
              let videoDevice,
              currentDeviceID == videoDevice.uniqueID else { return }
        let angle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = videoDevice.position == .front
        }
    }
}

private struct CameraCaptureFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class SavedAssetIdentifierBox: @unchecked Sendable {
    var value: String?
}
