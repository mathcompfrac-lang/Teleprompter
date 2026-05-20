import SwiftUI

/// 支付测试页面（仅用于开发和测试）
struct PaymentTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ticketManager = TicketManager.shared
    @StateObject private var storeManager = StoreManager.shared

    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationStack {
            List {
                // 当前状态
                Section("当前状态") {
                    HStack {
                        Text("免费剩余次数")
                        Spacer()
                        Text("\(ticketManager.freeUsesRemaining)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("总使用次数")
                        Spacer()
                        Text("\(ticketManager.totalUses)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("是否已订阅")
                        Spacer()
                        Text(storeManager.isPremium ? "✅ 是" : "❌ 否")
                            .foregroundColor(storeManager.isPremium ? .green : .secondary)
                    }

                    HStack {
                        Text("次卡剩余")
                        Spacer()
                        Text("\(ticketManager.perUseRemaining)")
                            .foregroundColor(.secondary)
                    }

                    if let type = storeManager.activeSubscriptionType {
                        HStack {
                            Text("订阅类型")
                            Spacer()
                            Text(type.displayName)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let endDate = storeManager.subscriptionEndDate {
                        HStack {
                            Text("到期时间")
                            Spacer()
                            Text(formatDate(endDate))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("是否可使用")
                        Spacer()
                        Text(ticketManager.canUseFeature ? "✅ 可以" : "❌ 不可以")
                            .foregroundColor(ticketManager.canUseFeature ? .green : .red)
                    }
                }

                // 模拟使用
                Section("模拟使用") {
                    Button("使用1次（启动悬浮窗）") {
                        let success = ticketManager.consumeUse()
                        alertMessage = success ? "使用成功，剩余：\(ticketManager.statusDescription)" : "使用失败，无可用额度"
                        showAlert = true
                    }
                    .disabled(!ticketManager.canUseFeature)
                }

                // 模拟购买（仅订阅）
                Section("模拟购买（仅用于测试）") {
                    Button("模拟购买次卡（1次）") {
                        ticketManager.addPerUseTickets(count: 1)
                        alertMessage = "模拟购买成功！已添加1次使用额度（仅本地测试）"
                        showAlert = true
                    }

                    Button("模拟购买次卡（10次）") {
                        ticketManager.addPerUseTickets(count: 10)
                        alertMessage = "模拟购买成功！已添加10次使用额度（仅本地测试）"
                        showAlert = true
                    }

                    Button("模拟购买月卡") {
                        ticketManager.extendSubscription(type: .monthly, duration: 1)
                        alertMessage = "模拟购买成功！月卡会员已生效（仅本地测试，不会实际扣费）"
                        showAlert = true
                    }

                    Button("模拟购买年卡") {
                        ticketManager.extendSubscription(type: .yearly, duration: 1)
                        alertMessage = "模拟购买成功！年卡会员已生效（仅本地测试，不会实际扣费）"
                        showAlert = true
                    }
                }

                // StoreKit 操作
                Section("StoreKit 操作") {
                    Button("加载产品") {
                        Task {
                            await storeManager.loadProducts()
                            alertMessage = "产品加载完成：\(storeManager.products.count) 个"
                            showAlert = true
                        }
                    }

                    Button("检查订阅状态") {
                        Task {
                            await storeManager.checkPurchasedProducts()
                            alertMessage = storeManager.isPremium ? "有生效的订阅" : "没有生效的订阅"
                            showAlert = true
                        }
                    }

                    Button("恢复购买") {
                        Task {
                            await storeManager.restorePurchases()
                            alertMessage = storeManager.isPremium ? "恢复成功" : "未找到可恢复的购买记录"
                            showAlert = true
                        }
                    }
                }

                // 重置数据
                Section("重置数据（测试用）") {
                    Button("重置为初始状态（免费7次）") {
                        resetToInitial()
                        alertMessage = "已重置为初始状态"
                        showAlert = true
                    }
                    .foregroundColor(.orange)

                    Button("清空所有数据") {
                        clearAllData()
                        alertMessage = "已清空所有数据"
                        showAlert = true
                    }
                    .foregroundColor(.red)
                }

                // 测试场景
                Section("快速测试场景") {
                    Button("场景1：新用户（7次免费）") {
                        resetToInitial()
                        alertMessage = "场景1设置完成：新用户，7次免费"
                        showAlert = true
                    }

                    Button("场景2：免费次数用完") {
                        ticketManager.freeUsesRemaining = 0
                        ticketManager.subscriptionTicket = nil
                        ticketManager.saveState()
                        alertMessage = "场景2设置完成：免费次数已用完，应显示付费墙"
                        showAlert = true
                    }

                    Button("场景3：有次卡凭证") {
                        ticketManager.freeUsesRemaining = 0
                        ticketManager.subscriptionTicket = nil
                        ticketManager.createPerUseTicket(uses: 5)
                        alertMessage = "场景3设置完成：有5次次卡额度"
                        showAlert = true
                    }

                    Button("场景4：月卡订阅中") {
                        ticketManager.freeUsesRemaining = 0
                        ticketManager.perUseTicket = nil
                        ticketManager.createSubscriptionTicket(type: .monthly, duration: 1)
                        alertMessage = "场景4设置完成：月卡会员生效中"
                        showAlert = true
                    }

                    Button("场景5：年卡订阅中") {
                        ticketManager.freeUsesRemaining = 0
                        ticketManager.createSubscriptionTicket(type: .yearly, duration: 1)
                        alertMessage = "场景4设置完成：年卡会员生效中"
                        showAlert = true
                    }
                }
            }
            .navigationTitle("支付测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func resetToInitial() {
        // 1. 清空本地 Keychain 凭证
        ticketManager.freeUsesRemaining = Constants.maxFreeTrials
        ticketManager.totalUses = 0
        ticketManager.subscriptionTicket = nil
        ticketManager.perUseTicket = nil
        ticketManager.saveState()
        
        // 2. 清空 Keychain 中的旧数据
        let keychain = KeychainWrapper()
        keychain.delete(key: "subscription_ticket")
        keychain.delete(key: "per_use_ticket")
        keychain.set(integer: Constants.maxFreeTrials, forKey: Constants.freeUsesRemainingKey)
        keychain.set(integer: 0, forKey: "total_uses_count")
        
        // 3. 重置 StoreKit 状态
        Task {
            await storeManager.resetPurchaseState()
            // 4. 同步苹果服务器的订阅状态
            await storeManager.checkPurchasedProducts()
        }
    }

    private func clearAllData() {
        // 1. 清空本地 Keychain 凭证
        ticketManager.freeUsesRemaining = 0
        ticketManager.totalUses = 0
        ticketManager.subscriptionTicket = nil
        ticketManager.perUseTicket = nil
        ticketManager.saveState()
        
        // 2. 清空 Keychain 中的旧数据
        let keychain = KeychainWrapper()
        keychain.delete(key: "subscription_ticket")
        keychain.delete(key: "per_use_ticket")
        keychain.set(integer: 0, forKey: Constants.freeUsesRemainingKey)
        keychain.set(integer: 0, forKey: "total_uses_count")
        
        // 3. 重置 StoreKit 状态
        Task {
            await storeManager.resetPurchaseState()
            // 4. 同步苹果服务器的订阅状态
            await storeManager.checkPurchasedProducts()
        }
    }
}

#Preview {
    PaymentTestView()
}
