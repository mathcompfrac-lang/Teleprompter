import Foundation
import SwiftUI

/// 试用次数管理
/// 记录免费试用次数，第 7 次后显示付费墙
final class UsageTracker: ObservableObject {

    static let shared = UsageTracker()

    @Published var remainingUses: Int
    @Published var isLocked: Bool

    private var hasUsedCurrentSession = false

    private init() {
        let used = UserDefaults.standard.integer(forKey: Constants.usageCountKey)
        let remaining = max(0, Constants.maxFreeTrials - used)
        remainingUses = remaining
        isLocked = remaining <= 0
    }

    /// 记录一次使用
    /// - Returns: 是否允许使用
    func recordUsage() -> Bool {
        guard !isLocked else { return false }
        guard !hasUsedCurrentSession else { return true }

        hasUsedCurrentSession = true
        let used = UserDefaults.standard.integer(forKey: Constants.usageCountKey) + 1
        UserDefaults.standard.set(used, forKey: Constants.usageCountKey)
        remainingUses = max(0, Constants.maxFreeTrials - used)

        if remainingUses <= 0 {
            isLocked = true
        }

        return true
    }

    /// 重置试用（调试用）
    func resetForTesting() {
        UserDefaults.standard.set(0, forKey: Constants.usageCountKey)
        remainingUses = Constants.maxFreeTrials
        isLocked = false
        hasUsedCurrentSession = false
    }
}

/// 试用限制视图
struct UsageLimitView: View {
    @ObservedObject var tracker: UsageTracker

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("免费试用已用完")
                .font(.title2)
                .bold()

            Text("您已用完 \(Constants.maxFreeTrials) 次免费试用。\n后续版本将支持付费解锁继续使用。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)

            // 调试按钮（上线前删除）
            Button("重置试用（调试）") {
                tracker.resetForTesting()
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
    }
}
