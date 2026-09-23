import SwiftUI
import UIKit

/// App 内提词拍摄页面。相机只录制采集流，提词窗仅叠加在预览层上方。
struct CameraTeleprompterView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var viewModel: TeleprompterViewModel
    let textColor: UIColor
    let highlightColor: UIColor
    let overlayOpacity: CGFloat

    @StateObject private var camera = CameraCaptureController()

    @State private var panelSize = CGSize(width: 340, height: 280)
    @State private var panelOffset = CGSize.zero
    @State private var panelDragOrigin = CGSize.zero
    @State private var resizeOrigin = CGSize(width: 340, height: 280)
    @State private var didInitializePanel = false

    @State private var countdownValue: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var alertMessage: String?
    @State private var alertOffersSettings = false
    @State private var showPendingExitConfirmation = false

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            if !camera.isRunning {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar

                GeometryReader { proxy in
                    panel(in: proxy.size)
                        .frame(width: panelSize.width, height: panelSize.height)
                        .position(
                            x: proxy.size.width / 2 + panelOffset.width,
                            y: proxy.size.height / 2 + panelOffset.height
                        )
                        .onAppear {
                            initializePanelIfNeeded(in: proxy.size)
                        }
                        .onChange(of: proxy.size) { _, newSize in
                            fitPanel(in: newSize)
                        }
                }
                .padding(.horizontal, 8)

                bottomBar
            }

            if let value = countdownValue {
                countdownOverlay(value: value)
            }

            if camera.isSaving {
                savingOverlay
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .interactiveDismissDisabled(
            camera.isRecording || camera.isSaving || camera.hasPendingSave || countdownValue != nil
        )
        .onAppear {
            // 语音识别和录像都会使用麦克风。首版进入拍摄页时停止语音链，
            // 保证相机录音稳定，正文仍可直接手势滚动。
            viewModel.stopScrolling()
            camera.requestPermissionsAndStart()
        }
        .onDisappear {
            countdownTask?.cancel()
            countdownValue = nil
            camera.stopSession()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            countdownTask?.cancel()
            countdownValue = nil
        }
        .onChange(of: camera.errorMessage) { _, message in
            guard let message else { return }
            alertOffersSettings = message.contains("权限") || message.contains("系统设置")
            alertMessage = message
        }
        .onChange(of: camera.saveConfirmation) { _, message in
            guard let message else { return }
            alertOffersSettings = false
            alertMessage = message
        }
        .alert("提示", isPresented: alertBinding) {
            if camera.hasPendingSave, !camera.isSaving {
                Button("重试保存") {
                    alertMessage = nil
                    camera.clearMessages()
                    DispatchQueue.main.async {
                        camera.retryPendingSave()
                    }
                }
            }
            if alertOffersSettings {
                Button("打开设置") {
                    openSystemSettings()
                    camera.clearMessages()
                }
            }
            Button("知道了", role: .cancel) {
                camera.clearMessages()
            }
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            "视频尚未保存",
            isPresented: $showPendingExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("重试保存") {
                camera.retryPendingSave()
            }
            Button("放弃视频并退出", role: .destructive) {
                camera.discardPendingSave()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后将无法恢复这段临时视频。")
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if camera.hasPendingSave {
                    showPendingExitConfirmation = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .foregroundStyle(.white)
            .disabled(camera.isRecording || camera.isSaving || countdownValue != nil)
            .accessibilityLabel("关闭提词拍摄")

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(camera.isRecording ? Color.red : (camera.isRunning ? Color.green : Color.orange))
                    .frame(width: 8, height: 8)
                Text(cameraStatusText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.black.opacity(0.55), in: Capsule())

            Spacer()

            Button {
                camera.switchCamera()
            } label: {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .foregroundStyle(.white)
            .disabled(!camera.isRunning || camera.isRecording || camera.isSaving || countdownValue != nil)
            .accessibilityLabel(camera.cameraPosition == .front ? "切换到后置摄像头" : "切换到前置摄像头")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()

            Button {
                handleRecordButton()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 5)
                        .frame(width: 76, height: 76)

                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.red)
                            .frame(width: 32, height: 32)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 60, height: 60)
                    }
                }
                .frame(width: 88, height: 88)
                .contentShape(Rectangle())
            }
            .disabled(
                (!camera.isRunning && !camera.isRecording)
                    || camera.isSaving
                    || camera.hasPendingSave
                    || countdownValue != nil
            )
            .accessibilityLabel(camera.isRecording ? "停止录像" : "开始录像")

            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var cameraStatusText: String {
        if camera.isSaving { return "正在保存" }
        if camera.hasPendingSave { return "视频待保存" }
        if camera.isRecording { return "录制中" }
        if camera.isRequestingPermissions { return "正在请求权限" }
        if camera.isRunning { return "准备就绪" }
        return "正在准备相机"
    }

    // MARK: - Teleprompter panel

    private func panel(in stageSize: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))

                Text("拖动提词窗")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text("\(Int(viewModel.scrollProgress * 100))%")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(movePanelGesture(in: stageSize))
            .accessibilityLabel("拖动提词窗把手")

            Divider()
                .overlay(.white.opacity(0.22))

            InteractiveTeleprompterScrollView(
                text: viewModel.text,
                fontSize: viewModel.fontSize,
                progress: viewModel.scrollProgress,
                highlightColor: highlightColor,
                textColor: textColor,
                onUserSeek: { progress in
                    viewModel.seekTo(progress: progress)
                }
            )
            .overlay(alignment: .bottomTrailing) {
                resizeHandle(in: stageSize)
            }
        }
        .background(Color.black.opacity(Double(max(0.3, min(1, overlayOpacity)))))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }

    private func resizeHandle(in stageSize: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(resizePanelGesture(in: stageSize))
            .accessibilityLabel("调整提词窗大小")
    }

    private func movePanelGesture(in stageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let candidate = CGSize(
                    width: panelDragOrigin.width + value.translation.width,
                    height: panelDragOrigin.height + value.translation.height
                )
                panelOffset = clampedOffset(candidate, panelSize: panelSize, stageSize: stageSize)
            }
            .onEnded { _ in
                panelDragOrigin = panelOffset
            }
    }

    private func resizePanelGesture(in stageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let horizontalDelta = layoutDirection == .rightToLeft
                    ? -value.translation.width
                    : value.translation.width
                let maxWidth = max(220, stageSize.width - 16)
                let maxHeight = max(160, stageSize.height - 16)
                panelSize = CGSize(
                    width: max(220, min(maxWidth, resizeOrigin.width + horizontalDelta)),
                    height: max(160, min(maxHeight, resizeOrigin.height + value.translation.height))
                )
                panelOffset = clampedOffset(panelOffset, panelSize: panelSize, stageSize: stageSize)
            }
            .onEnded { _ in
                resizeOrigin = panelSize
                panelDragOrigin = panelOffset
            }
    }

    private func initializePanelIfNeeded(in stageSize: CGSize) {
        guard !didInitializePanel else {
            fitPanel(in: stageSize)
            return
        }
        didInitializePanel = true
        panelSize = CGSize(
            width: max(220, min(340, stageSize.width - 16)),
            height: max(160, min(300, stageSize.height * 0.48))
        )
        resizeOrigin = panelSize
        panelOffset = .zero
        panelDragOrigin = .zero
    }

    private func fitPanel(in stageSize: CGSize) {
        panelSize.width = max(220, min(panelSize.width, max(220, stageSize.width - 16)))
        panelSize.height = max(160, min(panelSize.height, max(160, stageSize.height - 16)))
        resizeOrigin = panelSize
        panelOffset = clampedOffset(panelOffset, panelSize: panelSize, stageSize: stageSize)
        panelDragOrigin = panelOffset
    }

    private func clampedOffset(_ offset: CGSize, panelSize: CGSize, stageSize: CGSize) -> CGSize {
        let maxX = max(0, (stageSize.width - panelSize.width) / 2)
        let maxY = max(0, (stageSize.height - panelSize.height) / 2)
        return CGSize(
            width: max(-maxX, min(maxX, offset.width)),
            height: max(-maxY, min(maxY, offset.height))
        )
    }

    // MARK: - Recording

    private func handleRecordButton() {
        if camera.isRecording {
            camera.stopRecording()
            return
        }

        guard countdownTask == nil else { return }
        countdownTask = Task { @MainActor in
            for value in stride(from: 3, through: 1, by: -1) {
                countdownValue = value
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    countdownValue = nil
                    countdownTask = nil
                    return
                }
            }
            countdownValue = nil
            countdownTask = nil
            guard !Task.isCancelled, scenePhase == .active else { return }
            camera.startRecording()
        }
    }

    private func countdownOverlay(value: Int) -> some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
            Text("\(value)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 12)
                .accessibilityLabel("\(value)秒后开始录像")
        }
    }

    private var savingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
            Text("正在保存视频…")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Alerts

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                    camera.clearMessages()
                }
            }
        )
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Interactive text scroll view

/// 相机提词窗专用文本视图。用户滚动时把像素偏移换算成阅读进度，
/// 非用户操作时才根据 ViewModel 的进度更新位置，避免手势被程序滚动拉回。
private struct InteractiveTeleprompterScrollView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let progress: CGFloat
    let highlightColor: UIColor
    let textColor: UIColor
    let onUserSeek: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.indicatorStyle = .white
        scrollView.backgroundColor = .clear

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -52),
            label.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        context.coordinator.label = label
        context.coordinator.onUserSeek = onUserSeek
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onUserSeek = onUserSeek
        context.coordinator.updateText(
            text,
            fontSize: fontSize,
            progress: progress,
            highlightColor: highlightColor,
            textColor: textColor
        )
        scrollView.layoutIfNeeded()
        context.coordinator.applyProgrammaticProgress(progress, to: scrollView)
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.isUserInteracting = false
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var label: UILabel?
        var onUserSeek: ((CGFloat) -> Void)?
        var isUserInteracting = false

        private var isApplyingProgrammaticOffset = false
        private var currentText = ""
        private var currentFontSize: CGFloat = 0
        private var currentProgress: CGFloat = -1
        private var currentHighlightColor: UIColor?
        private var currentTextColor: UIColor?

        func updateText(
            _ text: String,
            fontSize: CGFloat,
            progress: CGFloat,
            highlightColor: UIColor,
            textColor: UIColor
        ) {
            let clampedProgress = max(0, min(1, progress))
            let needsUpdate = text != currentText
                || abs(fontSize - currentFontSize) > 0.25
                || abs(clampedProgress - currentProgress) > 0.001
                || currentHighlightColor?.isEqual(highlightColor) != true
                || currentTextColor?.isEqual(textColor) != true
            guard needsUpdate else { return }

            currentText = text
            currentFontSize = fontSize
            currentProgress = clampedProgress
            currentHighlightColor = highlightColor
            currentTextColor = textColor

            guard !text.isEmpty else {
                label?.attributedText = nil
                return
            }

            let nsText = text as NSString
            let totalLength = nsText.length
            let readLength = max(0, min(totalLength, Int(CGFloat(totalLength) * clampedProgress)))
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .natural
            paragraphStyle.lineSpacing = fontSize * 0.4

            let baseFont = UIFont.systemFont(ofSize: fontSize)
            let scaledFont = UIFontMetrics.default.scaledFont(for: baseFont)
            let attributedText = NSMutableAttributedString(string: text)
            if readLength > 0 {
                attributedText.addAttribute(
                    .foregroundColor,
                    value: highlightColor,
                    range: NSRange(location: 0, length: readLength)
                )
            }
            if totalLength > readLength {
                attributedText.addAttribute(
                    .foregroundColor,
                    value: textColor,
                    range: NSRange(location: readLength, length: totalLength - readLength)
                )
            }
            attributedText.addAttributes(
                [.font: scaledFont, .paragraphStyle: paragraphStyle],
                range: NSRange(location: 0, length: totalLength)
            )
            label?.attributedText = attributedText
        }

        func applyProgrammaticProgress(_ progress: CGFloat, to scrollView: UIScrollView) {
            guard !isUserInteracting,
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return }

            let range = scrollRange(for: scrollView)
            guard range.length > 0 else { return }
            let targetY = range.minimum + max(0, min(1, progress)) * range.length
            guard abs(scrollView.contentOffset.y - targetY) > 1 else { return }

            isApplyingProgrammaticOffset = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isApplyingProgrammaticOffset = false
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserInteracting = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isUserInteracting, !isApplyingProgrammaticOffset else { return }
            let range = scrollRange(for: scrollView)
            guard range.length > 0 else {
                onUserSeek?(0)
                return
            }
            let rawProgress = (scrollView.contentOffset.y - range.minimum) / range.length
            onUserSeek?(max(0, min(1, rawProgress)))
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                finishUserInteraction(in: scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserInteraction(in: scrollView)
        }

        private func finishUserInteraction(in scrollView: UIScrollView) {
            let range = scrollRange(for: scrollView)
            if range.length > 0 {
                let rawProgress = (scrollView.contentOffset.y - range.minimum) / range.length
                onUserSeek?(max(0, min(1, rawProgress)))
            }
            isUserInteracting = false
        }

        private func scrollRange(for scrollView: UIScrollView) -> (minimum: CGFloat, length: CGFloat) {
            let minimum = -scrollView.adjustedContentInset.top
            let maximum = max(
                minimum,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return (minimum, maximum - minimum)
        }
    }
}
