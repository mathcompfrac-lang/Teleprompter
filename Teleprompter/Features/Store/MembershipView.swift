import SwiftUI

/// 会员中心页面
struct MembershipView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ticketManager = TicketManager.shared
    @StateObject private var storeManager = StoreManager.shared

    @State private var showPaywall = false
    @State private var showTestView = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 会员状态卡片
                    statusCard

                    // 功能特权
                    benefitsSection

                    // 购买选项
                    purchaseSection

                    // 常见问题
                    faqSection
                }
                .padding()
            }
            .background(Color.teleprompterBackground)
            .navigationTitle("会员中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            #if DEBUG
            .sheet(isPresented: $showTestView) {
                PaymentTestView()
            }
            #endif
        }
    }

    // MARK: - 子视图

    private var statusCard: some View {
        VStack(spacing: 16) {
            // 图标和状态
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: statusIcon)
                    .font(.system(size: 50))
                    .foregroundColor(statusColor)
            }

            VStack(spacing: 8) {
                Text(statusTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(statusDescription)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 使用次数/有效期显示
            VStack(spacing: 12) {
                // 订阅信息（如果有）
                if storeManager.isPremium {
                    HStack {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.yellow)
                        Text("会员有效期: \(subscriptionExpiryText)")
                            .font(.subheadline)
                        Spacer()
                    }

                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("自动续费已开启，由 App Store 管理")
                            .font(.subheadline)
                        Spacer()
                    }
                }

                // 次卡信息（如果有）
                if ticketManager.hasPerUse {
                    HStack {
                        Image(systemName: "number.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("次卡剩余: \(ticketManager.perUseRemaining) 次")
                            .font(.subheadline)
                        Spacer()
                    }
                    
                    // 同时显示剩余免费次数（购买次卡后免费次数仍保留）
                    if ticketManager.freeUsesRemaining > 0 {
                        HStack {
                            Image(systemName: "gift.fill")
                                .foregroundColor(.green)
                            Text("免费剩余: \(ticketManager.freeUsesRemaining) 次（优先使用）")
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }

                // 免费次数（如果没有订阅也没有次卡）
                if !storeManager.isPremium && !ticketManager.hasPerUse && ticketManager.freeUsesRemaining > 0 {
                    HStack {
                        Image(systemName: "gift.fill")
                            .foregroundColor(.green)
                        Text("免费剩余: \(ticketManager.freeUsesRemaining) 次")
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color.teleprompterSecondaryBackground)
            .cornerRadius(12)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.teleprompterSecondaryBackground)
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }

    private var benefitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择适合的方式")
                .font(.headline)

            VStack(spacing: 12) {
                BenefitRow(
                    icon: "number.circle.fill",
                    title: "次卡",
                    description: "买固定次数，用完即止，无需续费"
                )
                BenefitRow(
                    icon: "infinity.circle.fill",
                    title: "无限使用",
                    description: "月卡/年卡有效期内无限次使用，自动续费"
                )
                BenefitRow(
                    icon: "crown.fill",
                    title: "全部功能",
                    description: "无论次卡还是订阅，均解锁全部提词器功能"
                )
            }
        }
        .padding()
        .background(Color.teleprompterSecondaryBackground)
        .cornerRadius(16)
    }

    private var purchaseSection: some View {
        VStack(spacing: 16) {
            if !ticketManager.canUseFeature {
                // 需要购买
                VStack(spacing: 12) {
                    Text("免费次数已用完")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("订阅会员后即可继续使用悬浮提词器")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()

                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Image(systemName: "crown.fill")
                        Text("立即订阅")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(12)
                }
            } else if ticketManager.hasPerUse {
                // 有次卡
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("增加次数或开通会员")
                            .font(.headline)
                    }
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
            } else if storeManager.isPremium {
                // 已是会员
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("管理订阅")
                            .font(.headline)
                    }
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
            } else {
                // 免费使用中
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Image(systemName: "crown.fill")
                        Text("订阅会员")
                            .font(.headline)
                    }
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                }
            }

            Button {
                Task {
                    await storeManager.restorePurchases()
                }
            } label: {
                VStack(spacing: 4) {
                    Text("恢复购买")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("换设备或重新安装后恢复已购会员")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.top, 8)

            #if DEBUG
            Button {
                showTestView = true
            } label: {
                Text("开发者测试")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
            #endif
        }
    }

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("常见问题")
                .font(.headline)

            VStack(alignment: .leading, spacing: 16) {
                FAQItem(
                    question: "购买后可以退款吗？",
                    answer: "虚拟商品一经购买，不支持退款。如有问题请联系苹果客服。"
                )
                FAQItem(
                    question: "如何取消自动续费？",
                    answer: "在 iPhone 的「设置 > Apple ID > 订阅」中取消即可，取消后当前有效期仍可使用。"
                )
                FAQItem(
                    question: "月卡和年卡有什么区别？",
                    answer: "月卡按月自动续费；年卡按年自动续费，价格更优惠。两者均自动续费，无需手动操作。"
                )
                FAQItem(
                    question: "次卡和订阅有什么区别？",
                    answer: "次卡购买固定次数，用完即止，不会自动续费；月卡/年卡在有效期内无限使用，到期自动续费。"
                )
                FAQItem(
                    question: "如何恢复购买？",
                    answer: "换设备或重新安装后，点击「恢复购买」按钮即可恢复已有订阅。"
                )
                FAQItem(
                    question: "会员可以在多台设备使用吗？",
                    answer: "可以，使用同一 Apple ID 登录即可在不同设备间同步。"
                )
            }
        }
        .padding()
        .background(Color.teleprompterSecondaryBackground)
        .cornerRadius(16)
    }

    // MARK: - 辅助计算属性

    private var statusIcon: String {
        if storeManager.isPremium {
            return "crown.fill"
        } else if ticketManager.canUseFeature {
            return "gift.fill"
        } else {
            return "lock.fill"
        }
    }

    private var statusColor: Color {
        if storeManager.isPremium {
            return .yellow
        } else if ticketManager.canUseFeature {
            return .green
        } else {
            return .orange
        }
    }

    private var statusTitle: String {
        if storeManager.isPremium {
            if let type = storeManager.activeSubscriptionType {
                switch type {
                case .monthly: return "月度会员"
                case .yearly: return "年度会员"
                case .perUse: return "次卡用户"
                }
            }
            return "会员"
        } else if ticketManager.hasPerUse {
            return "次卡用户"
        } else if ticketManager.canUseFeature {
            return "免费使用中"
        } else {
            return "需要购买"
        }
    }

    private var statusDescription: String {
        if storeManager.isPremium {
            return "自动续费中，享受全部会员特权"
        } else if ticketManager.hasPerUse {
            let perUse = ticketManager.perUseRemaining
            let free = ticketManager.freeUsesRemaining
            if free > 0 {
                return "次卡剩余 \(perUse) 次，免费剩余 \(free) 次"
            } else {
                return "次卡用户，剩余 \(perUse) 次"
            }
        } else if ticketManager.canUseFeature {
            return "新用户免费体验中"
        } else {
            return "购买后即可继续使用"
        }
    }

    private var subscriptionExpiryText: String {
        if let expiry = storeManager.subscriptionEndDate {
            let now = Date()
            let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: expiry)
            
            if let days = components.day, days > 0 {
                return "\(days) 天"
            } else if let hours = components.hour, hours > 0 {
                return "\(hours) 小时"
            } else if let minutes = components.minute, minutes > 0 {
                return "\(minutes) 分钟"
            } else {
                return "即将过期"
            }
        }
        return "未知"
    }
}

// MARK: - 预览

#Preview {
    MembershipView()
}

// MARK: - 公共子组件

struct BenefitRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

struct FAQItem: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(answer)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
