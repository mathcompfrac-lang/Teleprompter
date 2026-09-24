import SwiftUI
import SwiftData
import Combine
import CoreTransferable
import Network
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// 主内容视图
/// 集成了脚本选择 + 提词控制 + 画中画管理
struct ContentView: View {

    // MARK: - 环境

    @Environment(\.modelContext) private var modelContext

    // MARK: - 查询

    @Query private var settingsList: [SettingsModel]

    // MARK: - 状态对象

    @StateObject private var pipManager = PIPManager.shared

    // MARK: - 本地状态

    @State private var selectedScript: ScriptModel?
    @State private var showScriptList = false
    @State private var showSettings = false
    @State private var showAudioPermission = false
    @State private var showNewScript = false
    @State private var showCameraRecorder = false
    @State private var selectedSubtitleVideoItem: PhotosPickerItem?
    @State private var selectedSubtitleVideo: SelectedSubtitleVideo?
    @State private var isImportingSubtitleVideo = false
    @State private var subtitleVideoImportError: String?
    @State private var showPIPUnavailableAlert = false
    @State private var isPIPStarting = false

    // MARK: - 主题监听

    @State private var currentTheme: ColorScheme? = nil
    /// 当前高亮颜色（预览区用，随设置页变化）
    @State private var previewHighlightColor: UIColor = UIColor(hexString: "#FFD700") ?? .systemYellow
    /// 当前文本颜色（预览区未读部分）
    @State private var previewTextColor: UIColor = .white

    // MARK: - 联网提示和倒计时状态
    @State private var showCountdown = false
    @State private var countdownValue = 3
    @State private var countdownTimer: Timer?
    
    private func reloadTheme() {
        let raw = UserDefaults.standard.string(forKey: "themeMode")
            ?? ThemeMode.system.rawValue
        // 首次启动写入默认值
        if UserDefaults.standard.string(forKey: "themeMode") == nil {
            UserDefaults.standard.set(raw, forKey: "themeMode")
        }
        currentTheme = ThemeMode(rawValue: raw)?.colorScheme
    }

    // ViewModel（@StateObject 自己管理生命周期）
    @StateObject private var viewModel = TeleprompterViewModel()

    // MARK: - 主体

    var body: some View {
        ZStack {
            // 背景
            Color.teleprompterBackground
                .ignoresSafeArea()

            if showAudioPermission {
                // 未授权麦克风
                AudioPermissionView(onGranted: {
                    withAnimation { showAudioPermission = false }
                })
            } else {
                // 主界面
                mainContent
            }

            if isImportingSubtitleVideo {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()

                ProgressView("正在导入视频…")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
            }

            // 倒计时显示
            if showCountdown {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("准备开始")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text("\(countdownValue)")
                        .font(.system(size: 80, weight: .bold))
                        .foregroundColor(.accentColor)
                    Text("秒后启动悬浮窗")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                }
                .transition(.scale)
            }
        }
        .onAppear {
            reloadTheme()
            initializeApp()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadTheme()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView { newSettings in
                applySettings(newSettings)
            }
        }
        .sheet(isPresented: $showScriptList) {
            NavigationStack {
                ScriptListView(onSelectScript: { script in
                    selectScript(script)
                })
            }
        }
        .sheet(isPresented: $showNewScript) {
            ScriptEditorView(
                script: nil,
                modelContext: modelContext,
                onSave: {
                    // 保存后刷新脚本列表（如果有刚刚创建的脚本，加载最新的）
                    let descriptor = FetchDescriptor<ScriptModel>(
                        sortBy: [SortDescriptor(\ScriptModel.updatedAt, order: .reverse)]
                    )
                    if let scripts = try? modelContext.fetch(descriptor), let latest = scripts.first {
                        selectScript(latest)
                    }
                }
            )
        }
        .fullScreenCover(isPresented: $showCameraRecorder) {
            CameraTeleprompterView(
                viewModel: viewModel,
                textColor: UIColor(
                    hexString: settingsList.first?.textColorHex ?? "#FFFFFF"
                ) ?? .white,
                highlightColor: UIColor(
                    hexString: settingsList.first?.highlightColorHex ?? "#FFD700"
                ) ?? .yellow,
                overlayOpacity: CGFloat(settingsList.first?.pipOpacity ?? 0.85)
            )
        }
        .fullScreenCover(item: $selectedSubtitleVideo) { video in
            ImportedVideoSubtitleView(sourceURL: video.fileURL)
        }
        .onChange(of: selectedSubtitleVideoItem) { _, item in
            guard let item else { return }
            importSubtitleVideo(from: item)
        }
        .alert("画中画不可用", isPresented: $showPIPUnavailableAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("当前设备（模拟器）不支持画中画功能。\n请在真机上运行以使用画中画悬浮提词。")
        }
        .alert(
            "视频导入失败",
            isPresented: Binding(
                get: { subtitleVideoImportError != nil },
                set: { if !$0 { subtitleVideoImportError = nil } }
            )
        ) {
            Button("取消", role: .cancel) {}
        } message: {
            Text(subtitleVideoImportError ?? "")
        }
        .onChange(of: pipManager.isPIPActive) { _, isActive in
            if !isActive {
                // 画中画退出时停止滚动
                viewModel.stopScrolling()
            }
        }
        // 强制设置窗口界面样式（比 preferredColorScheme 更底层，保证生效）
        .onChange(of: currentTheme) { _, newTheme in
            applyWindowTheme(newTheme)
        }
        .onAppear {
            applyWindowTheme(currentTheme)
        }
    }

    /// 设置窗口级别的 UserInterfaceStyle
    private func applyWindowTheme(_ scheme: ColorScheme?) {
        let style: UIUserInterfaceStyle
        switch scheme {
        case .dark:  style = .dark
        case .light: style = .light
        default:     style = .unspecified
        }
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.overrideUserInterfaceStyle = style }
    }

    // MARK: - 主界面

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            // 顶部：脚本选择 + 操作栏
            topBar

            subtitleRecognitionEntry

            // 中间：提词器主区域
            if !viewModel.text.isEmpty {
                teleprompterArea(vm: viewModel)
            } else {
                noScriptSelected
            }

            // 底部：控制面板
            if !viewModel.text.isEmpty {
                TeleprompterControlView(
                    viewModel: viewModel,
                    pipManager: pipManager,
                    onStartPIP: { startPIP() }
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private var subtitleRecognitionEntry: some View {
        PhotosPicker(
            selection: $selectedSubtitleVideoItem,
            matching: .videos,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("识别字幕")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("从系统相册选择视频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(pipManager.isPIPActive || isImportingSubtitleVideo)
        .accessibilityLabel("识别字幕")
        .accessibilityHint("从系统相册选择视频")
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack {
            // 左侧：标题
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedScript?.title ?? "悬浮提词器")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let script = selectedScript {
                    Text("\(script.content.count) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 右侧按钮（放大 1.5 倍）
            HStack(spacing: 16) {
                // App 内提词拍摄
                Button(action: {
                    viewModel.stopScrolling()
                    showCameraRecorder = true
                }) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 23))
                }
                .disabled(viewModel.text.isEmpty || pipManager.isPIPActive)
                .accessibilityLabel("提词拍摄")

                // 新建脚本
                Button(action: { showNewScript = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 25))
                }
                .disabled(pipManager.isPIPActive)

                // 选择脚本
                Button(action: { showScriptList = true }) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 25))
                }
                .disabled(pipManager.isPIPActive)

                // 设置
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 25))
                }

            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.teleprompterBackground)
    }

    // MARK: - 未选脚本

    private var noScriptSelected: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "text.alignleft")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))

            Text("选择一个脚本开始使用")
                .font(.title3)
                .foregroundColor(.secondary)

            Button("新建脚本") {
                showNewScript = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("浏览我的脚本") {
                showScriptList = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }

    // MARK: - 提词器区域

    private func teleprompterArea(vm: TeleprompterViewModel) -> some View {
        VStack(spacing: 8) {
            // 文本预览（可跟随进度条滚动）
            TeleprompterPreviewView(
                text: vm.text,
                fontSize: vm.fontSize * 0.8,
                scrollProgress: vm.scrollProgress,
                highlightColor: UIColor(hexString: "#FFD700") ?? .yellow,
                textColor: .black
            )
            .background(Color.teleprompterSecondaryBackground)
            .cornerRadius(12)
            .padding(.horizontal)
            .overlay(
                // 进度指示
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(Int(vm.scrollProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.8))
                            .cornerRadius(4)
                            .padding(8)
                    }
                }
            )

            // 语音能量指示 + 降级滚动控制
            if vm.scrollMode == .voice && vm.isScrolling {
                VStack(spacing: 8) {
                    // 第一行：语音状态 + 能量条
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundColor(vm.isSpeaking ? .green : .secondary)
                        Text(vm.isSpeaking ? "正在说话..." : "等待语音...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        energyBar(level: vm.audioLevel)
                    }

                    // 第二行：降级定时滚动开关 + 速度
                    HStack {
                        Toggle(isOn: Binding(
                            get: { vm.fallbackScrollEnabled },
                            set: { vm.fallbackScrollEnabled = $0 }
                        )) {
                            Text("无麦克风时自动滚动")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                        if vm.fallbackScrollEnabled {
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "speedometer")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Stepper("\(vm.fallbackScrollSpeed) 字/秒", value: Binding(
                                    get: { vm.fallbackScrollSpeed },
                                    set: { vm.fallbackScrollSpeed = $0 }
                                ), in: 1...20)
                                .font(.caption)
                                .fixedSize()
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func energyBar(level: Float) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        Float(i) / 10.0 < level
                            ? Color.accentColor
                            : Color.secondary.opacity(0.2)
                    )
                    .frame(width: 3, height: 8 + CGFloat(i) * 2)
            }
        }
    }

    // MARK: - 初始化

    private func initializeApp() {
        // 创建设置模型（如不存在）
        createInitialSettingsIfNeeded()

        // 检查麦克风权限
        if AudioPermission.status == .notDetermined {
            // 暂不显示权限页，首次启动提词时再请求
        }

        // 加载上次使用的脚本
        loadLastScript()
    }

    private func createInitialSettingsIfNeeded() {
        let descriptor = FetchDescriptor<SettingsModel>()
        let count = (try? modelContext.fetch(descriptor).count) ?? 0
        if count == 0 {
            let defaultSettings = SettingsModel()
            modelContext.insert(defaultSettings)
            try? modelContext.save()
        }
    }

    private func loadLastScript() {
        // 从 UserDefaults 恢复上次使用的脚本
        // 具体实现由 ScriptListView 处理
    }

    // MARK: - 动作

    private func selectScript(_ script: ScriptModel) {
        selectedScript = script

        viewModel.loadText(script.content)
        viewModel.fontSize = Constants.defaultFontSize
        viewModel.scrollSpeed = Constants.defaultScrollSpeed

        // 加载设置
        loadSettingsIntoViewModel()

        showScriptList = false
    }

    private func importSubtitleVideo(from item: PhotosPickerItem) {
        guard !isImportingSubtitleVideo else { return }
        isImportingSubtitleVideo = true
        subtitleVideoImportError = nil

        Task { @MainActor in
            defer {
                isImportingSubtitleVideo = false
                selectedSubtitleVideoItem = nil
            }

            do {
                guard let video = try await item.loadTransferable(
                    type: SelectedSubtitleVideo.self
                ) else {
                    throw SubtitleVideoImportFailure()
                }
                selectedSubtitleVideo = video
            } catch is CancellationError {
                return
            } catch {
                subtitleVideoImportError = error.localizedDescription
            }
        }
    }

    private func loadSettingsIntoViewModel() {
        let descriptor = FetchDescriptor<SettingsModel>()
        if let s = try? modelContext.fetch(descriptor).first {
            viewModel.fontSize = CGFloat(s.fontSize)
            viewModel.scrollSpeed = s.scrollSpeed
            viewModel.voiceSpeedMultiplier = s.voiceSpeedMultiplier
        }
    }

    private func startPIP() {
        let vm = viewModel

        // 检查画中画是否支持
        guard pipManager.isPIPAvailable else {
            showPIPUnavailableAlert = true
            return
        }

        // 语音模式下使用倒计时
        if vm.scrollMode == .voice {
            // 检查麦克风权限
            if AudioPermission.status != .granted {
                Task {
                    let granted = await AudioPermission.request()
                    if !granted {
                        showAudioPermission = true
                        return
                    }
                }
            }

            // 开始倒计时
            if !showCountdown {
                startCountdown()
            }
        } else {
            // 手动模式直接启动
            actuallyStartPIP()
        }
    }

    /// 开始倒计时（3-2-1）
    private func startCountdown() {
        showCountdown = true
        countdownValue = 3
        
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                self.countdownValue -= 1
                if self.countdownValue <= 0 {
                    self.stopCountdown()
                    self.actuallyStartPIP()
                }
            }
        }
    }
    
    /// 停止倒计时
    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        showCountdown = false
        countdownValue = 3
    }

    /// 实际启动画中画（倒计时后调用）
    private func actuallyStartPIP() {
        let vm = viewModel

        guard let windowScene = UIApplication.shared.keyWindowScene,
              let window = windowScene.windows.first else {
            print("[ContentView] 无法获取窗口")
            return
        }

        // 获取当前设置
        let currentSettings = settingsList.first
        let pipFontSize = vm.fontSize
        let pipTextColor = UIColor(hexString: currentSettings?.textColorHex ?? "#FFFFFF") ?? .white
        let pipHighlightColor = UIColor(hexString: currentSettings?.highlightColorHex ?? "#FFD700") ?? .yellow

        let success = pipManager.startPIP(
            in: window,
            text: vm.text,
            fontSize: pipFontSize,
            widthRatio: 1.0,
            textColor: pipTextColor,
            highlightColor: pipHighlightColor
        )

        if success {
            // 同步当前进度
            pipManager.setScrollProgress(vm.scrollProgress)

            // 如果正在滚动，保持同步
            if vm.isScrolling && !vm.isPaused {
                // DisplayLink 会持续同步偏移量
            }
        }
    }

    @MainActor private func applySettings(_ newSettings: TeleprompterSettings) {
        print("[ContentView] applySettings: textColor=\(newSettings.textColor) highlight=\(newSettings.highlightColor) opacity=\(newSettings.pipOpacity)")
        viewModel.fontSize = newSettings.fontSize
        viewModel.scrollSpeed = newSettings.scrollSpeed
        viewModel.voiceSpeedMultiplier = newSettings.voiceSpeedMultiplier

        // 保存预览区颜色（TeleprompterPreviewView 随 @State 更新）
        previewHighlightColor = newSettings.highlightColor
        previewTextColor = newSettings.textColor

        // 同步 PIP 外观设置
        pipManager.updateTextColor(newSettings.textColor)
        pipManager.updateHighlightColor(newSettings.highlightColor)
        pipManager.updateOpacity(newSettings.pipOpacity)
        pipManager.updatePIPSize(ratio: newSettings.pipWidth / 100)

        if pipManager.isPIPActive {
            pipManager.updateFontSize(newSettings.fontSize)
        }
    }

    /// 让主视图的文本预览跟随进度条滚动
    private func scrollPreviewTo(proxy: ScrollViewProxy, progress: CGFloat, vm: TeleprompterViewModel) {
        // 不再使用，已替换为 TeleprompterPreviewView
    }
}

private struct SelectedSubtitleVideo: Identifiable, Transferable {
    let id = UUID()
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { receivedFile in
            let stagingDirectory = TeleprompterVideoImportStaging.directoryURL
            TeleprompterVideoImportStaging.removeExpiredFiles()
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            let pathExtension = receivedFile.file.pathExtension.isEmpty
                ? "mov"
                : receivedFile.file.pathExtension
            let destinationURL = stagingDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension)
            do {
                try FileManager.default.copyItem(at: receivedFile.file, to: destinationURL)
                return SelectedSubtitleVideo(fileURL: destinationURL)
            } catch {
                TeleprompterVideoImportStaging.removeFileIfOwned(at: destinationURL)
                throw error
            }
        }
    }
}

private struct SubtitleVideoImportFailure: LocalizedError {
    var errorDescription: String? {
        String(localized: "无法读取选择的视频")
    }
}

// MARK: - 提词器预览视图（UIScrollView 包装器）

struct TeleprompterPreviewView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var scrollProgress: CGFloat
    var highlightColor: UIColor
    var textColor: UIColor

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = UIColor.label
        label.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            label.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        context.coordinator.label = label
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.updateText(text, fontSize: fontSize, progress: scrollProgress, highlightColor: highlightColor, textColor: textColor)
        // 强制布局，确保 contentSize 已根据 label 内容计算完成
        scrollView.layoutIfNeeded()

        guard let label = context.coordinator.label else { return }

        // 计算可滚动范围
        let padding: CGFloat = 32
        let totalContentHeight = label.bounds.height + padding
        let visibleHeight = scrollView.bounds.height
        let maxOffset = max(0, totalContentHeight - visibleHeight)

        // 计算高亮位置（已读文本的底部）
        let readLength = Int(CGFloat(text.count) * scrollProgress)
        let highlightOffset = offsetForCharacterIndex(readLength, in: label)

        // 目标：让高亮位置在屏幕下方，保留至少4行可见
        // 即：scrollView.contentOffset.y + visibleHeight > highlightOffset + 4 * lineHeight
        let lineHeight = fontSize * 1.8
        let minVisibleOffset = highlightOffset - visibleHeight + lineHeight * 4 + 16 // 16 = bottom padding

        // 限制在有效范围内
        let targetY = max(0, min(maxOffset, minVisibleOffset))

        if maxOffset > 0, abs(scrollView.contentOffset.y - targetY) > 1 {
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }
    }

    /// 计算指定字符索引在 label 中的垂直偏移量
    private func offsetForCharacterIndex(_ index: Int, in label: UILabel) -> CGFloat {
        guard index > 0, let attributedText = label.attributedText else { return 0 }
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: label.bounds.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(index, attributedText.length - 1))
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return lineRect.maxY + 16 // + top padding
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        weak var label: UILabel?
        weak var scrollView: UIScrollView?
        private var currentText: String = ""
        private var currentFontSize: CGFloat = 28
        private var currentProgress: CGFloat = 0

        func updateText(_ text: String, fontSize: CGFloat, progress: CGFloat, highlightColor: UIColor, textColor: UIColor) {
            let textChanged = text != currentText
            let fontSizeChanged = abs(fontSize - currentFontSize) > 0.5
            let progressChanged = abs(progress - currentProgress) > 0.01
            guard textChanged || fontSizeChanged || progressChanged else { return }
            currentText = text
            currentFontSize = fontSize
            currentProgress = progress

            guard !text.isEmpty else {
                label?.text = ""
                return
            }

            // 已读部分高亮，未读部分正常颜色
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineSpacing = fontSize * 0.4

            let mutableAttr = NSMutableAttributedString(string: text)
            let totalLength = text.count

            let readLength = min(max(0, Int(CGFloat(totalLength) * progress)), totalLength)
            if readLength > 0 {
                mutableAttr.addAttribute(.foregroundColor, value: highlightColor, range: NSRange(location: 0, length: readLength))
            }

            let unreadStart = readLength
            let unreadLength = totalLength - unreadStart
            if unreadLength > 0 {
                mutableAttr.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: unreadStart, length: unreadLength))
            }

            mutableAttr.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize), range: NSRange(location: 0, length: totalLength))
            mutableAttr.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: totalLength))

            label?.attributedText = mutableAttr
            label?.sizeToFit()
        }
    }
}

// MARK: - 预览

#Preview {
    ContentView()
        .modelContainer(for: [ScriptModel.self, SettingsModel.self])
}
