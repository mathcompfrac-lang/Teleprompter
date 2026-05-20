import Foundation
import SwiftUI
import Combine
import Speech

/// 提词器核心 ViewModel
@MainActor
final class TeleprompterViewModel: ObservableObject {

    // MARK: - 发布的状态

    @Published var text: String = ""
    @Published var scrollProgress: CGFloat = 0
    @Published var isScrolling = false
    @Published var isPaused = false
    @Published var scrollMode: ScrollMode = .manual
    @Published var isListening = false
    @Published var audioLevel: Float = 0
    @Published var isSpeaking = false
    @Published var totalLines: Int = 0
    @Published var currentLine: Int = 0
    @Published var fallbackScrollEnabled = false
    @Published var fallbackScrollSpeed = 5

    enum ScrollMode: String, CaseIterable {
        case manual = "手动"
        case voice = "语音"
        var icon: String {
            switch self {
            case .manual: return "hand.tap"
            case .voice: return "waveform"
            }
        }
    }

    // MARK: - 设置

    var scrollSpeed: Double = Constants.defaultScrollSpeed
    var fontSize: CGFloat = Constants.defaultFontSize
    var voiceSpeedMultiplier: Double = 1.0

    // MARK: - 依赖

    private let pipManager = PIPManager.shared
    private let speechDetector = SpeechDetector()

    // MARK: - 内部状态

    private var charIndex: Int = 0
    private var charsPerLine: Int = 12
    private var scrollTimer: Timer?
    private var fallbackTimer: Timer?
    private var displayLink: CADisplayLink?
    private var targetOffset: CGFloat = 0
    private(set) var currentOffset: CGFloat = 0

    // 语音识别状态
    private var lastRecognizedText: String = ""
    private var lastMatchTime: Date = Date()
    
    // 能量辅助（检测到说话但没有识别结果时辅助推进）
    private var speakingFrameCount: Int = 0
    private var energyBoostChars: Double = 0

    // MARK: - 初始化

    init() {
        setupSpeechDetection()
    }

    private func setupSpeechDetection() {
        // 能量检测（辅助用）
        speechDetector.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                guard let self = self else { return }
                self.isSpeaking = speaking
                if speaking {
                    self.speakingFrameCount += 1
                } else {
                    self.speakingFrameCount = max(0, self.speakingFrameCount - 2)
                }
            }
            .store(in: &cancellables)

        speechDetector.$currentRMS
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        // 语音识别回调 - 主要推进方式
        speechDetector.onRecognizedText = { [weak self] recognized in
            guard let self = self,
                  self.scrollMode == .voice,
                  !self.isPaused,
                  !self.text.isEmpty else { return }

            // 计算增量
            let incremental = self.extractIncremental(newText: recognized, lastText: self.lastRecognizedText)
            self.lastRecognizedText = recognized

            // 匹配推进
            if !incremental.isEmpty {
                let matchedIndex = self.fastMatch(recognized: recognized, in: self.text)
                if matchedIndex > self.charIndex {
                    let now = Date()
                    let elapsed = now.timeIntervalSince(self.lastMatchTime)
                    self.lastMatchTime = now
                    
                    // 如果匹配间隔太长，说明可能有延迟，加速推进
                    if elapsed > 0.5 && matchedIndex - self.charIndex < 3 {
                        // 可能漏了识别，用能量辅助推进
                        self.charIndex = matchedIndex + 2
                    } else {
                        self.charIndex = matchedIndex
                    }
                    self.charIndex = min(self.charIndex, self.text.count)
                    self.updateScrollFromCharIndex()
                }
            }
        }
    }

    private func extractIncremental(newText: String, lastText: String) -> String {
        if newText.count > lastText.count {
            let startIndex = newText.index(newText.startIndex, offsetBy: lastText.count)
            return String(newText[startIndex...])
        }
        // 识别修正，重新匹配
        return newText
    }

    /// 快速匹配：在当前位置附近搜索
    private func fastMatch(recognized: String, in script: String) -> Int {
        let cleanRecognized = recognized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !cleanRecognized.isEmpty else { return charIndex }

        let scriptChars = Array(script)
        let recognizedChars = Array(cleanRecognized)

        // 策略1：从当前位置往后找连续匹配
        var matchLen = 0
        var si = charIndex
        var ri = 0

        // 从当前位置开始匹配
        while si < scriptChars.count && ri < recognizedChars.count {
            if scriptChars[si] == recognizedChars[ri] {
                matchLen += 1
                si += 1
                ri += 1
            } else if ri < recognizedChars.count - 1 {
                // 尝试跳过识别文本中的一个字（可能是识别错误）
                ri += 1
            } else {
                break
            }
        }

        // 如果匹配了至少1个字，直接返回
        if matchLen >= 1 {
            return charIndex + matchLen
        }

        // 策略2：滑动搜索最近的位置
        let searchStart = max(0, charIndex - 10)
        let searchEnd = min(scriptChars.count, charIndex + 100)

        for start in searchStart..<searchEnd {
            var len = 0
            var i = start
            var j = 0

            while i < scriptChars.count && j < recognizedChars.count {
                if scriptChars[i] == recognizedChars[j] {
                    len += 1
                    i += 1
                    j += 1
                } else {
                    break
                }
            }

            if len >= 2 {
                return start + len
            }
        }

        return charIndex
    }

    // MARK: - 加载文本

    func loadText(_ text: String) {
        self.text = text
        charIndex = 0
        scrollProgress = 0
        currentOffset = 0
        targetOffset = 0
        isScrolling = false
        isPaused = false
        lastRecognizedText = ""
        speakingFrameCount = 0
        energyBoostChars = 0
        updateLineInfo()
    }

    func reset() {
        charIndex = 0
        scrollProgress = 0
        currentOffset = 0
        targetOffset = 0
        isScrolling = false
        isPaused = false
        lastRecognizedText = ""
        speakingFrameCount = 0
        energyBoostChars = 0
        speechDetector.reset()
        stopScrollTimer()
    }

    // MARK: - 滚动控制

    func startScrolling() {
        guard !text.isEmpty, !isScrolling else { return }
        isScrolling = true
        isPaused = false

        if scrollMode == .voice {
            startVoiceDetection()
        }

        startDisplayLink()
    }

    func pauseScrolling() {
        isPaused = true
        stopScrollTimer()
        if scrollMode == .voice {
            stopVoiceDetection()
        }
    }

    func resumeScrolling() {
        guard isScrolling else { return }
        isPaused = false
        if scrollMode == .voice {
            startVoiceDetection()
        }
    }

    func stopScrolling() {
        isScrolling = false
        isPaused = false
        stopScrollTimer()
        stopVoiceDetection()
        stopDisplayLink()
    }

    func toggleScrollMode() {
        let wasScrolling = isScrolling && !isPaused
        if wasScrolling { stopScrolling() }
        scrollMode = scrollMode == .manual ? .voice : .manual
        if wasScrolling { startScrolling() }
    }

    func advanceText(by chars: Int) {
        guard !text.isEmpty else { return }
        charIndex = min(charIndex + chars, text.count)
        updateScrollFromCharIndex()
    }

    func seekTo(progress: CGFloat) {
        guard !text.isEmpty else { return }
        let clampedProgress = max(0, min(1, progress))
        charIndex = Int(clampedProgress * CGFloat(text.count))
        scrollProgress = clampedProgress
        updateLineInfo()
        pipManager.setScrollProgress(clampedProgress)
    }

    // MARK: - 定时器

    private func startScrollTimer() {
        stopScrollTimer()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.scrollMode == .manual, !self.isPaused else { return }
            Task { @MainActor [weak self] in
                self?.tickManualScroll()
            }
        }
        RunLoop.main.add(scrollTimer!, forMode: .common)
    }

    private func stopScrollTimer() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func tickManualScroll() {
        guard !text.isEmpty else { return }
        let charsPerSecond = scrollSpeed / 60.0
        let charsPerTick = charsPerSecond / 60.0
        if charsPerTick >= 1 {
            advanceText(by: Int(charsPerTick))
        } else {
            accumulatedCharProgress += charsPerTick
            if accumulatedCharProgress >= 1.0 {
                let chars = Int(accumulatedCharProgress)
                advanceText(by: chars)
                accumulatedCharProgress -= Double(chars)
            }
        }
    }

    private var accumulatedCharProgress: Double = 0

    // MARK: - 显示链接

    private func startDisplayLink() {
        stopDisplayLink()
        displayLink = CADisplayLink(target: self, selector: #selector(tickDisplayLink))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tickDisplayLink(_ link: CADisplayLink) {
        // 能量辅助：检测到说话但识别没跟上时，小幅度推进
        if scrollMode == .voice && isScrolling && !isPaused && !fallbackScrollEnabled {
            if speakingFrameCount > 5 && isSpeaking {
                energyBoostChars += scrollSpeed / 60.0 * voiceSpeedMultiplier / 60.0
                if energyBoostChars >= 1.0 {
                    let chars = Int(energyBoostChars)
                    // 只在识别没跟上时辅助推进
                    charIndex = min(charIndex + chars, text.count)
                    energyBoostChars -= Double(chars)
                    updateScrollFromCharIndex()
                }
            } else {
                energyBoostChars = 0
            }
            
            if !isSpeaking {
                speakingFrameCount = max(0, speakingFrameCount - 1)
            }
        }

        // 平滑动画
        let diff = targetOffset - currentOffset
        if abs(diff) < 0.5 {
            currentOffset = targetOffset
        } else {
            currentOffset += diff * 0.3
        }

        // 同步到悬浮窗
        if pipManager.isPIPActive {
            pipManager.setScrollProgress(scrollProgress)
            pipManager.setCharIndex(charIndex)
        }
    }

    // MARK: - 语音检测

    private func startVoiceDetection() {
        isListening = true
        lastRecognizedText = ""
        speakingFrameCount = 0
        energyBoostChars = 0
        lastMatchTime = Date()

        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async {
                    self?.actuallyStartDetection()
                }
            }
        } else {
            actuallyStartDetection()
        }
    }

    private func actuallyStartDetection() {
        do {
            try speechDetector.start()
        } catch {
            print("[TeleprompterViewModel] 语音检测启动失败: \(error)")
        }
        if fallbackScrollEnabled {
            startFallbackTimer()
        }
    }

    private func stopVoiceDetection() {
        speechDetector.stop()
        stopFallbackTimer()
        isListening = false
        speakingFrameCount = 0
        energyBoostChars = 0
    }

    private func startFallbackTimer() {
        stopFallbackTimer()
        guard fallbackScrollEnabled else { return }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.scrollMode == .voice, !self.isPaused, self.fallbackScrollEnabled else { return }
            Task { @MainActor [weak self] in
                self?.advanceText(by: self?.fallbackScrollSpeed ?? 5)
            }
        }
        RunLoop.main.add(fallbackTimer!, forMode: .common)
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    // MARK: - 辅助

    private func updateScrollFromCharIndex() {
        guard !text.isEmpty else { return }

        let progress = CGFloat(charIndex) / CGFloat(text.count)
        scrollProgress = min(progress, 1.0)

        let estimatedLineHeight = fontSize * 1.8
        let lines = CGFloat(charIndex) / CGFloat(charsPerLine)
        targetOffset = lines * estimatedLineHeight

        updateLineInfo()
        pipManager.setScrollProgress(scrollProgress)
        pipManager.setCharIndex(charIndex)
    }

    private func updateLineInfo() {
        guard !text.isEmpty else {
            totalLines = 0
            currentLine = 0
            return
        }
        let estimatedCharsPerLine = max(5, Int(360.0 / (fontSize * 0.6)))
        charsPerLine = estimatedCharsPerLine
        totalLines = (text.count / charsPerLine) + 1
        currentLine = (charIndex / charsPerLine) + 1
    }

    private var cancellables = Set<AnyCancellable>()

    deinit {
        scrollTimer?.invalidate()
        fallbackTimer?.invalidate()
        displayLink?.invalidate()
        speechDetector.stop()
    }
}
