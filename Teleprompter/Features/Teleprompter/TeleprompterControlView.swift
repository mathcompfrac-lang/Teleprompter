import SwiftUI

/// 提词器控制面板
/// 用户控制画中画启动/暂停/停止、切换模式、进度等
struct TeleprompterControlView: View {

    // MARK: - 依赖注入

    @ObservedObject var viewModel: TeleprompterViewModel
    @ObservedObject var pipManager: PIPManager

    // MARK: - 回调

    var onStartPIP: (() -> Void)?

    // MARK: - 本地状态

    @State private var showSpeedSlider = false
    @State private var editingSpeed: Double = 120
    /// 模拟语音定时器（仅用于模拟器调试）
    @State private var simulateTimer: Timer?

    // MARK: - 主体

    var body: some View {
        VStack(spacing: 16) {
            // 模式选择
            modeSelector

            // 进度条
            progressControl

            // 主控制按钮
            mainControls

            // 速度设置
            if showSpeedSlider {
                speedControl
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.teleprompterSecondaryBackground)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    // MARK: - 模式选择

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(TeleprompterViewModel.ScrollMode.allCases, id: \.self) { mode in
                Button(action: {
                    if viewModel.scrollMode != mode {
                        viewModel.toggleScrollMode()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.caption)
                        Text(mode.rawValue)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(viewModel.scrollMode == mode ? Color.accentColor : Color.clear)
                    .foregroundColor(viewModel.scrollMode == mode ? .white : .primary)
                    .cornerRadius(8)
                }
            }
        }
        .background(Color.teleprompterBackground.opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - 进度控制

    private var progressControl: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { viewModel.scrollProgress },
                    set: { viewModel.seekTo(progress: $0) }
                ),
                in: 0...1
            )
            .tint(.accentColor)

            HStack {
                Text("\(Int(viewModel.scrollProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if viewModel.totalLines > 0 {
                    Text("\(viewModel.currentLine)/\(viewModel.totalLines) 行")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if pipManager.isPIPActive {
                    Label("浮动中", systemImage: "pip")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    // MARK: - 主控制按钮

    private var mainControls: some View {
        HStack(spacing: 20) {
            // 速度设置
            Button(action: {
                withAnimation { showSpeedSlider.toggle() }
            }) {
                Image(systemName: "speedometer")
                    .font(.system(size: 25))
            }
            .buttonStyle(.plain)

            Spacer()

            // 重置
            Button(action: {
                viewModel.reset()
            }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 25))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.text.isEmpty)

            // 播放/暂停
            Button(action: {
                if viewModel.isScrolling {
                    if viewModel.isPaused {
                        viewModel.resumeScrolling()
                    } else {
                        viewModel.pauseScrolling()
                    }
                } else {
                    viewModel.startScrolling()
                }
            }) {
                Image(systemName: viewModel.isScrolling && !viewModel.isPaused
                    ? "pause.circle.fill"
                    : "play.circle.fill"
                )
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.text.isEmpty)

            // 前进
            Button(action: {
                viewModel.advanceText(by: 10)
            }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 25))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.text.isEmpty)

            // 模拟语音（仅调试）
            #if targetEnvironment(simulator)
            Button(action: {
                toggleSimulateSpeech()
            }) {
                Image(systemName: simulateTimer != nil ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 25))
                    .foregroundColor(simulateTimer != nil ? .green : .orange)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.text.isEmpty || viewModel.scrollMode != .voice)
            #endif

            Spacer()

            // 画中画启动/停止
            Button(action: {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                if pipManager.isPIPActive {
                    pipManager.stopPIP()
                } else {
                    onStartPIP?()
                }
            }) {
                Image(systemName: pipManager.isPIPActive
                    ? "pip.exit"
                    : "pip.enter"
                )
                .font(.system(size: 30))
                .foregroundColor(pipManager.isPIPActive ? .red : .accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 速度控制

    private var speedControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("语速: \(Int(viewModel.scrollSpeed)) 字/分")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if viewModel.scrollMode == .voice {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.caption2)
                            .foregroundColor(viewModel.isSpeaking ? .green : .secondary)
                        Text("x\(String(format: "%.1f", viewModel.voiceSpeedMultiplier))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Slider(
                value: Binding(
                    get: { viewModel.scrollSpeed },
                    set: {
                        viewModel.scrollSpeed = $0
                        editingSpeed = $0
                    }
                ),
                in: Constants.minScrollSpeed...Constants.maxScrollSpeed,
                step: 10
            )
            .tint(.accentColor)

            HStack {
                Text("慢")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("快")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.teleprompterBackground.opacity(0.3))
        .cornerRadius(12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - 模拟语音（仅模拟器调试）

    #if targetEnvironment(simulator)
    private func toggleSimulateSpeech() {
        if let timer = simulateTimer {
            timer.invalidate()
            simulateTimer = nil
            viewModel.isSpeaking = false
        } else {
            viewModel.isSpeaking = true
            simulateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    // 每 0.5 秒推进 3 个字，模拟说话
                    viewModel.advanceText(by: 3)
                }
            }
        }
    }
    #endif
}

// MARK: - 预览

#Preview {
    TeleprompterControlView(
        viewModel: TeleprompterViewModel(),
        pipManager: PIPManager.shared
    )
    .padding()
    .background(Color.teleprompterBackground)
}
