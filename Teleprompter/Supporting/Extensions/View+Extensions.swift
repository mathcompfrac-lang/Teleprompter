import SwiftUI

// MARK: - View Extensions

extension View {
    /// 条件修饰符
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// 占位文本
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

// MARK: - Color Extensions

extension Color {
    static let teleprompterAccent = Color.accentColor
    static let teleprompterBackground = Color(.systemBackground)
    static let teleprompterSecondaryBackground = Color(.secondarySystemBackground)
    static let teleprompterText = Color(.label)
    static let teleprompterSecondaryText = Color(.secondaryLabel)
}

// MARK: - UIApplication Extensions

extension UIApplication {
    var keyWindowScene: UIWindowScene? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    }

    var rootViewController: UIViewController? {
        keyWindowScene?
            .windows
            .filter { $0.isKeyWindow }
            .first?
            .rootViewController
    }
}

// MARK: - UIScreen Extensions

extension UIScreen {
    static var currentWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    static var currentHeight: CGFloat {
        UIScreen.main.bounds.height
    }
}
