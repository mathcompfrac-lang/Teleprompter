import UIKit
import AVKit

/// 悬浮窗内容 ViewController
/// 独立管理高亮和滚动，让正在阅读的文字保持在中央
final class PIPContentViewController: AVPictureInPictureVideoCallViewController {

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let textLabel = UILabel()

    // MARK: - 状态

    private var fontSize: CGFloat = 28
    private var currentText: String = ""
    private var currentProgress: CGFloat = 0
    private var textColor: UIColor = .white
    private var highlightColor: UIColor = UIColor(hexString: "#FFD700") ?? .yellow
    private var pipOpacity: CGFloat = 0.85
    private var currentCharIndex: Int = 0

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        updateLabelWidth()
        if currentCharIndex > 0 {
            scrollToCharIndex(currentCharIndex)
        }
    }

    // MARK: - UI

    private func setupUI() {
        view.isOpaque = false
        view.backgroundColor = .clear
        
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInset = UIEdgeInsets(top: 20, left: 16, bottom: 80, right: 16)
        view.addSubview(scrollView)

        textLabel.numberOfLines = 0
        textLabel.font = .systemFont(ofSize: fontSize)
        scrollView.addSubview(textLabel)

        applyAttributedText()
        applyBackgroundColor()
    }

    private func updateLabelWidth() {
        let width = view.bounds.width - 32
        let maxSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let textSize = textLabel.sizeThatFits(maxSize)
        textLabel.frame = CGRect(origin: .zero, size: textSize)
        scrollView.contentSize = textSize
    }

    // MARK: - 背景

    private func applyBackgroundColor() {
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: pipOpacity)
    }

    func restoreAppearance() {
        applyBackgroundColor()
    }

    // MARK: - 内容更新

    func updateText(_ text: String, fontSize: CGFloat, progress: CGFloat) {
        self.fontSize = fontSize
        self.currentText = text
        self.currentProgress = progress
        textLabel.font = .systemFont(ofSize: fontSize)
        applyAttributedText()
        textLabel.sizeToFit()
        scrollView.contentSize = textLabel.bounds.size
        updateLabelWidth()
        updateScrollPosition(progress: progress)
        applyBackgroundColor()
    }

    private func applyAttributedText() {
        guard !currentText.isEmpty else {
            textLabel.attributedText = nil
            return
        }

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = fontSize * 0.4

        let mutableAttr = NSMutableAttributedString(string: currentText)
        let totalLength = currentText.count
        let readLength = min(max(0, Int(CGFloat(totalLength) * currentProgress)), totalLength)

        if readLength > 0 {
            mutableAttr.addAttribute(.foregroundColor, value: highlightColor, range: NSRange(location: 0, length: readLength))
        }
        if totalLength - readLength > 0 {
            mutableAttr.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: readLength, length: totalLength - readLength))
        }
        mutableAttr.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize), range: NSRange(location: 0, length: totalLength))
        mutableAttr.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: totalLength))

        textLabel.attributedText = mutableAttr
    }

    func updateScrollPosition(progress: CGFloat) {
        guard !currentText.isEmpty else { return }
        currentProgress = progress
        applyAttributedText()

        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        let offset = progress * maxOffset
        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, min(maxOffset, offset))), animated: false)
    }

    func scrollToCharIndex(_ index: Int) {
        currentCharIndex = index
        guard !currentText.isEmpty, index > 0 else { return }

        guard let attributedText = textLabel.attributedText else { return }
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: textLabel.bounds.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)

        let clampedIndex = min(index, attributedText.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let highlightY = lineRect.midY

        let visibleHeight = scrollView.bounds.height - scrollView.contentInset.top - scrollView.contentInset.bottom
        let targetY = highlightY - visibleHeight / 2 - scrollView.contentInset.top

        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        let clampedY = max(0, min(maxOffset, targetY))

        let progress = CGFloat(index) / CGFloat(currentText.count)
        currentProgress = progress
        applyAttributedText()

        scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
    }

    func setScrollOffset(_ offset: CGFloat) {
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, min(maxOffset, offset))), animated: false)
    }

    var scrollProgress: CGFloat { currentProgress }

    func updateFontSize(_ size: CGFloat) {
        fontSize = size
        textLabel.font = .systemFont(ofSize: size)
        applyAttributedText()
        textLabel.sizeToFit()
        scrollView.contentSize = textLabel.bounds.size
        updateLabelWidth()
    }

    func updateHighlightColor(_ color: UIColor) {
        highlightColor = color
        applyAttributedText()
    }

    func updateTextColor(_ color: UIColor) {
        textColor = color
        applyAttributedText()
    }

    func updateOpacity(_ opacity: CGFloat) {
        pipOpacity = opacity
        applyBackgroundColor()
    }
}