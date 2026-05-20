import UIKit
import AVKit
import Combine

/// 画中画管理器
@MainActor
final class PIPManager: NSObject, ObservableObject {

    static let shared = PIPManager()

    @Published var isPIPActive = false
    @Published var isPIPAvailable = false

    private var pipController: AVPictureInPictureController?
    private(set) var contentViewController: PIPContentViewController?
    private var currentText: String = ""

    private let sourceView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        return view
    }()

    override init() {
        super.init()
        checkAvailability()
    }

    private func checkAvailability() {
        isPIPAvailable = AVPictureInPictureController.isPictureInPictureSupported()
    }

    let maxPIPSize = CGSize(width: 3000, height: 1687)

    func startPIP(in sourceWindow: UIWindow, text: String, fontSize: CGFloat, widthRatio: CGFloat = 1.0, textColor: UIColor = .white, highlightColor: UIColor = UIColor(hexString: "#FFD700") ?? .yellow) -> Bool {
        guard isPIPAvailable else { return false }
        guard pipController == nil || !(pipController?.isPictureInPictureActive ?? false) else { return false }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }

        if sourceView.superview == nil {
            sourceWindow.addSubview(sourceView)
            sourceWindow.layoutIfNeeded()
        }

        let size = CGSize(width: maxPIPSize.width * widthRatio, height: maxPIPSize.height * widthRatio)
        let contentVC = PIPContentViewController()
        contentVC.preferredContentSize = size
        contentVC.updateText(text, fontSize: fontSize, progress: 0)
        contentVC.updateTextColor(textColor)
        contentVC.updateHighlightColor(highlightColor)
        self.contentViewController = contentVC
        self.currentText = text

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentVC
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.pipController = controller

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let ctrl = self.pipController else { return }
            if ctrl.isPictureInPicturePossible {
                ctrl.startPictureInPicture()
            }
        }
        return true
    }

    func updateText(_ text: String, fontSize: CGFloat, progress: CGFloat = 0) {
        currentText = text
        contentViewController?.updateText(text, fontSize: fontSize, progress: progress)
    }

    func updateFontSize(_ fontSize: CGFloat) {
        guard !currentText.isEmpty else { return }
        let currentProgress = contentViewController?.scrollProgress ?? 0
        contentViewController?.updateText(currentText, fontSize: fontSize, progress: currentProgress)
    }

    func updatePIPSize(ratio: CGFloat) {
        let size = CGSize(width: maxPIPSize.width * ratio, height: maxPIPSize.height * ratio)
        contentViewController?.preferredContentSize = size
    }

    func setScrollProgress(_ progress: CGFloat) {
        contentViewController?.updateScrollPosition(progress: progress)
    }

    /// 设置当前字符索引（用于悬浮窗精确定位）
    func setCharIndex(_ index: Int) {
        contentViewController?.scrollToCharIndex(index)
    }

    func setScrollOffset(_ offset: CGFloat) {
        contentViewController?.setScrollOffset(offset)
    }

    func updateTextColor(_ color: UIColor) {
        contentViewController?.updateTextColor(color)
    }

    func updateHighlightColor(_ color: UIColor) {
        contentViewController?.updateHighlightColor(color)
    }

    func updateOpacity(_ opacity: CGFloat) {
        contentViewController?.updateOpacity(opacity)
    }

    func stopPIP() {
        guard let controller = pipController, controller.isPictureInPictureActive else {
            cleanup()
            return
        }
        controller.stopPictureInPicture()
    }

    private func cleanup() {
        pipController?.delegate = nil
        pipController = nil
        contentViewController = nil
        sourceView.removeFromSuperview()
        isPIPActive = false
    }
}

extension PIPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPIPActive = true
            // PIP 启动后重新设置样式（系统可能覆盖了）
            self.contentViewController?.restoreAppearance()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPIPActive = false
            self.cleanup()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isPIPActive = false
            self.cleanup()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
