import AVFoundation
import Combine
import Speech

/// 语音识别器
/// 使用 SFSpeechRecognizer 做实时语音转文字
final class SpeechDetector: NSObject, ObservableObject {
    // MARK: - 发布的状态

    @Published var isSpeaking = false
    @Published var currentRMS: Float = 0

    // MARK: - 回调

    /// 识别到增量文本时回调（只传新增的部分）
    var onRecognizedText: ((String) -> Void)?

    // MARK: - 私有属性

    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private var isRunning = false

    private let threshold: Float = Constants.speechThreshold

    // MARK: - SFSpeechRecognizer

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 上次完整的识别文本
    private var lastTranscription: String = ""

    deinit { stop() }

    // MARK: - 公共方法

    func start() throws {
        guard !isRunning else { return }

        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechDetector", code: -1, userInfo: [NSLocalizedDescriptionKey: "语音识别不可用"])
        }

        // 创建识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw NSError(domain: "SpeechDetector", code: -2, userInfo: [NSLocalizedDescriptionKey: "创建识别请求失败"])
        }
        request.shouldReportPartialResults = true
        request.taskHint = .unspecified

        // 启动识别任务
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        lastTranscription = ""
        print("[SpeechDetector] 启动")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        speechRecognizer = nil
        isRunning = false
        isSpeaking = false
        lastTranscription = ""
        print("[SpeechDetector] 停止")
    }

    func reset() {
        lastTranscription = ""
    }

    // MARK: - 结果处理

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard let result = result else {
            if let error = error {
                print("[SpeechDetector] 识别错误: \(error.localizedDescription)")
            }
            return
        }

        let text = result.bestTranscription.formattedString

        // 计算增量文本
        let incremental: String
        if text.count > lastTranscription.count {
            let startIndex = text.index(text.startIndex, offsetBy: lastTranscription.count)
            incremental = String(text[startIndex...])
        } else if text.count < lastTranscription.count {
            // 识别修正导致文本变短，传完整文本
            incremental = text
        } else {
            incremental = ""
        }

        lastTranscription = text

        // 只回调增量部分
        if !incremental.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onRecognizedText?(incremental)
            }
        }

        // 识别结束时重启（保持持续识别）
        if result.isFinal {
            print("[SpeechDetector] 当前识别结束，准备重启...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.restartRecognition()
            }
        }
    }

    /// 识别结束时无缝重启
    private func restartRecognition() {
        guard isRunning else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .unspecified
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }

        print("[SpeechDetector] 识别已重启")
    }

    // MARK: - 音频处理（能量检测）

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        var rms: Float = 0
        for i in 0..<frameLength { rms += channelDataValue[i] * channelDataValue[i] }
        rms = sqrt(rms / Float(frameLength))
        let normalizedRMS = min(rms * 5, 1.0)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentRMS = normalizedRMS
            self.isSpeaking = normalizedRMS > self.threshold
        }
    }
}
