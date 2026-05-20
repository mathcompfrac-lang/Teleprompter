import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var ticketManager = TicketManager.shared
    
    /// 选中的产品类型
    @State private var selectedProduct: ProductType?
    @State private var showPerUsePicker = false
    @State private var perUseCount = 1
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var dismissAfterSuccess = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. 皇冠图标 + 标题
                    headerSection
                    
                    // 2. 当前状态卡片
                    statusCardSection
                    
                    // 3. 方案选择（包含绿色提示横幅）
                    plansSection
                    
                    // 4. 购买按钮
                    purchaseButtonSection
                    
                    // 5. 底部链接
                    bottomLinksSection
                }
                .padding()
            }
            .navigationTitle("升级会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("购买失败", isPresented: $showError) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .alert("购买成功", isPresented: $showSuccess) {
                Button("确定", role: .cancel) {
                    if dismissAfterSuccess {
                        dismiss()
                    }
                }
            } message: {
                Text(successMessage)
            }
            .task {
                await storeManager.loadProducts()
            }
        }
    }
    
    // MARK: - 1. 头部区域
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text("解锁无限使用")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("免费额度用完后，选择适合的方式继续使用")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top)
    }
    
    // MARK: - 2. 当前状态卡片
    private var statusCardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let endDate = storeManager.subscriptionEndDate {
                Label("会员到期时间: \(formatDate(endDate))", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else if ticketManager.freeUsesRemaining > 0 {
                Label("免费试用剩余: \(ticketManager.freeUsesRemaining) 次", systemImage: "gift.fill")
                    .foregroundColor(.blue)
            } else if ticketManager.perUseRemaining > 0 {
                Label("次卡剩余: \(ticketManager.perUseRemaining) 次", systemImage: "ticket.fill")
                    .foregroundColor(.orange)
            } else {
                Label("免费额度已用完", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    // MARK: - 3. 方案选择
    private var plansSection: some View {
        VStack(spacing: 15) {
            // 已有订阅时的绿色提示横幅（在方案选择区内部顶部）
            if storeManager.isPremium {
                subscriptionNoticeSection
            }
            
            // 方案说明
            planGuideSection
            
            // 次卡卡片
            perUseCard
            
            // 月卡卡片
            subscriptionCard(type: .monthly, isPopular: false)
            
            // 年卡卡片
            subscriptionCard(type: .yearly, isPopular: true)
        }
    }
    
    // MARK: - 订阅提示横幅
    private var subscriptionNoticeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("您已有生效的订阅", systemImage: "info.circle.fill")
                .foregroundColor(.green)
                .fontWeight(.medium)
            
            if let endDate = storeManager.subscriptionEndDate {
                Text("到期时间: \(formatDate(endDate))")
                    .font(.caption)
            }
            
            Text("订阅由 App Store 自动管理，到期后自动续费，无需手动操作。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("如需切换方案，可直接选择其他订阅。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let type = storeManager.activeSubscriptionType {
                Text("当前方案: \(type.displayName)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .cornerRadius(10)
    }
    
    // MARK: - 方案说明区
    private var planGuideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择适合的方式")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            HStack(spacing: 16) {
                Label("次卡 - 买固定次数", systemImage: "number.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Label("会员 - 无限使用+自动续费", systemImage: "infinity.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Label("全部功能 - 均解锁", systemImage: "crown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    // MARK: - 次卡卡片
    private var perUseCard: some View {
        let isDisabled = storeManager.isPremium
        let isSelected = selectedProduct == .perUse
        
        return VStack(spacing: 0) {
            Button {
                if !isDisabled {
                    selectedProduct = .perUse
                    showPerUsePicker = true
                }
            } label: {
                HStack {
                    Image(systemName: "number")
                        .foregroundColor(.blue)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("次卡")
                            .fontWeight(.medium)
                        Text("买固定次数，用完即止")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if isDisabled {
                        Text("会员无需按次")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let product = storeManager.perUseProduct {
                        Text(product.price, format: product.priceFormatStyle)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                    
                    if isSelected && !isDisabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title3)
                    }
                }
                .padding()
                .background(isSelected && !isDisabled ? Color.blue.opacity(0.1) : Color(.systemGray6))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected && !isDisabled ? Color.blue : Color.clear, lineWidth: 2)
                )
            }
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1.0)
            
            // 次卡选择器
            if showPerUsePicker && isSelected && !isDisabled {
                VStack(spacing: 12) {
                    // 数量显示
                    HStack {
                        Button {
                            if perUseCount > 1 { perUseCount -= 1 }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                        
                        Text("\(perUseCount) 次")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .frame(minWidth: 80)
                        
                        Button {
                            if perUseCount < 100 { perUseCount += 1 }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    // 快速选择按钮（直接设置数量，不调起支付）
                    HStack(spacing: 10) {
                        ForEach([1, 5, 10, 20, 50], id: \.self) { count in
                            Button {
                                perUseCount = count
                            } label: {
                                Text("\(count)次")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(perUseCount == count ? Color.blue : Color.blue.opacity(0.1))
                                    .foregroundColor(perUseCount == count ? .white : .blue)
                                    .cornerRadius(5)
                            }
                        }
                    }
                    
                    // 总价显示（使用 priceFormatStyle 格式化）
                    if let product = storeManager.perUseProduct {
                        let total = product.price * Decimal(perUseCount)
                        Text("总计: \(total, format: product.priceFormatStyle)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.top, 8)
            }
        }
    }
    
    // MARK: - 订阅卡片
    private func subscriptionCard(type: ProductType, isPopular: Bool) -> some View {
        let product = storeManager.product(for: type)
        let isCurrentPlan = storeManager.activeSubscriptionType == type
        // 检查是否有待生效的降级订阅（年卡降级月卡，年卡到期前不能买任何订阅）
        let hasPendingDowngrade = hasPendingDowngradeSubscription()
        // 判断是否允许跨级切换
        let canCrossGrade = canCrossGradeSubscription(to: type)
        // 禁用条件：相同订阅类型，或有待生效降级，或不满足跨级条件
        let isDisabled = isCurrentPlan || hasPendingDowngrade || !canCrossGrade
        let isSelected = selectedProduct == type
        
        return VStack(spacing: 0) {
            // 最优惠标签
            if isPopular && !isDisabled {
                HStack {
                    Spacer()
                    Text("最优惠")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange)
                        .cornerRadius(5, corners: [.topRight, .bottomLeft])
                }
                .padding(.trailing, -1)
                .padding(.top, -1)
            }
            
            Button {
                if !isDisabled {
                    selectedProduct = type
                    showPerUsePicker = false
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type.displayName)
                            .fontWeight(.medium)
                        
                        if let product = product {
                            let period = type == .monthly ? "月" : "年"
                            Text("\(product.price, format: product.priceFormatStyle)/\(period)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if type == .yearly, let product = product {
                            let monthlyEquiv = product.price / 12
                            Text("相当于 \(monthlyEquiv, format: product.priceFormatStyle)/月")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Spacer()
                    
                    if isCurrentPlan {
                        Text("当前方案")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(5)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title3)
                    }
                }
                .padding()
                .background(isSelected && !isDisabled ? Color.blue.opacity(0.1) : Color(.systemGray6))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected && !isDisabled ? Color.blue : Color.clear, lineWidth: 2)
                )
            }
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1.0)
        }
    }
    
    // MARK: - 4. 购买按钮
    private var purchaseButtonSection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await handlePurchase() }
            } label: {
                HStack {
                    if storeManager.purchaseState == .purchasing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                    Text(purchaseButtonTitle)
                        .fontWeight(.bold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(canPurchase ? Color.blue : Color.gray)
                .cornerRadius(10)
            }
            .disabled(!canPurchase)
            
            // 恢复购买
            Button {
                Task {
                    await storeManager.restorePurchases()
                    if case .success = storeManager.purchaseState {
                        successMessage = "购买恢复成功"
                        dismissAfterSuccess = true
                        showSuccess = true
                    }
                }
            } label: {
                Text("恢复购买")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .disabled(storeManager.purchaseState == .purchasing || storeManager.purchaseState == .restoring)
        }
    }
    
    // MARK: - 5. 底部链接
    private var bottomLinksSection: some View {
        VStack(spacing: 12) {
            HStack {
                Link("隐私政策", destination: URL(string: "https://example.com/privacy")!)
                Spacer()
                Link("服务条款", destination: URL(string: "https://example.com/terms")!)
            }
            .font(.caption)
            .foregroundColor(.blue)
            
            // Test 版本重置按钮
            #if DEBUG
            Button {
                resetAllData()
            } label: {
                Text("重置测试数据")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            #endif
        }
        .padding(.top)
    }
    
    /// 重置所有测试数据
    private func resetAllData() {
        // 1. 重置 TicketManager
        ticketManager.freeUsesRemaining = Constants.maxFreeTrials
        ticketManager.totalUses = 0
        ticketManager.subscriptionTicket = nil
        ticketManager.perUseTicket = nil
        ticketManager.saveState()
        
        // 2. 清空 Keychain
        let keychain = KeychainWrapper()
        keychain.delete(key: "subscription_ticket")
        keychain.delete(key: "per_use_ticket")
        keychain.set(integer: Constants.maxFreeTrials, forKey: Constants.freeUsesRemainingKey)
        keychain.set(integer: 0, forKey: "total_uses_count")
        
        // 3. 重置 StoreManager
        Task {
            await storeManager.resetPurchaseState()
            await storeManager.checkPurchasedProducts()
        }
        
        // 4. 重置 UI 状态
        selectedProduct = nil
        perUseCount = 1
        showPerUsePicker = false
        
        successMessage = "已重置所有数据"
        dismissAfterSuccess = false
        showSuccess = true
    }
    
    // MARK: - 购买按钮文案
    private var purchaseButtonTitle: String {
        guard let product = selectedProduct else {
            return "选择方案"
        }
        
        if product == .perUse {
            guard let perUseProduct = storeManager.perUseProduct else {
                return "购买 \(perUseCount) 次"
            }
            let unitPrice = Double(truncating: perUseProduct.price as NSNumber)
            let total = unitPrice * Double(perUseCount)
            return String(format: "购买 %d 次 ¥%.0f", perUseCount, total)
        } else {
            guard let storeProduct = storeManager.product(for: product) else {
                return "订阅\(product.displayName)"
            }
            let price = storeProduct.price
            let period = product == .monthly ? "月" : "年"
            let formattedPrice = price.formatted(storeProduct.priceFormatStyle)
            
            if storeManager.activeSubscriptionType == .monthly && product == .yearly {
                return "升级至年卡 \(formattedPrice)/\(period)"
            } else if storeManager.activeSubscriptionType == .yearly && product == .monthly {
                return "切换至月卡 \(formattedPrice)/\(period)"
            } else {
                return "订阅\(product.displayName) \(formattedPrice)/\(period)"
            }
        }
    }
    
    // MARK: - 是否可以购买
    private var canPurchase: Bool {
        guard selectedProduct != nil else { return false }
        guard storeManager.purchaseState != .purchasing else { return false }
        return true
    }
    
    // MARK: - 购买处理
    private func handlePurchase() async {
        guard let product = selectedProduct else { return }
        
        // 有订阅时禁止购买次卡
        if product == .perUse && storeManager.isPremium {
            errorMessage = "您已有会员订阅，无需购买次卡"
            showError = true
            return
        }
        
        // 获取产品并购买
        let storeProduct: Product?
        if product == .perUse {
            storeProduct = storeManager.perUseProduct
        } else {
            storeProduct = storeManager.product(for: product)
        }
        
        guard let storeProduct = storeProduct else {
            errorMessage = "产品未找到"
            showError = true
            return
        }
        
        // 次卡传递数量，订阅默认1
        let quantity = product == .perUse ? perUseCount : 1
        await storeManager.purchase(storeProduct, quantity: quantity)
        await handlePurchaseState()
    }
    
    // MARK: - 处理购买状态
    @MainActor
    private func handlePurchaseState() async {
        switch storeManager.purchaseState {
        case .success:
            guard let productID = storeManager.pendingPurchaseProductID else {
                errorMessage = "购买状态异常"
                showError = true
                storeManager.purchaseState = .idle
                return
            }
            
            // 根据 productID 处理凭证
            switch productID {
            case ProductType.perUse.rawValue:
                // 次卡：添加次数
                ticketManager.addPerUseTickets(count: perUseCount)
                successMessage = "已获得 \(perUseCount) 次使用权限"
                dismissAfterSuccess = false
                
            case ProductType.monthly.rawValue:
                // 月卡：检查是否已有有效订阅
                if let existingTicket = ticketManager.subscriptionTicket,
                   existingTicket.isValid {
                    if existingTicket.type == .yearly {
                        // 场景：年卡降级月卡
                        let expiryDate = formatDate(existingTicket.expiresAt ?? Date())
                        successMessage = "月卡订阅成功，将于\(expiryDate)年卡到期后自动转为月卡"
                    }
                    // 相同订阅类型已在UI置灰，不会走到这里
                } else {
                    // 新购月卡
                    ticketManager.extendSubscription(type: .monthly, duration: 1)
                    successMessage = "月卡订阅成功！会员权益已生效，到期后自动续费"
                }
                dismissAfterSuccess = true
                
            case ProductType.yearly.rawValue:
                // 年卡：检查是否已有有效订阅
                if let existingTicket = ticketManager.subscriptionTicket,
                   existingTicket.isValid {
                    if existingTicket.type == .monthly {
                        // 场景：月卡升级年卡
                        successMessage = "年卡升级成功！立即享受年卡权益"
                    }
                    // 相同订阅类型已在UI置灰，不会走到这里
                } else {
                    // 新购年卡
                    ticketManager.extendSubscription(type: .yearly, duration: 1)
                    successMessage = "年卡订阅成功！会员权益已生效，到期后自动续费"
                }
                dismissAfterSuccess = true
                
            default:
                successMessage = "购买成功"
                dismissAfterSuccess = false
            }
            
            showSuccess = true
            storeManager.purchaseState = .idle
            
        case .failed(let message):
            errorMessage = message
            showError = true
            
        default:
            break
        }
    }
    
    // MARK: - 辅助方法
    
    /// 格式化价格（使用 CNY，清除 CNY 前缀）
    private func formatPrice(_ price: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        
        if let string = formatter.string(from: price as NSNumber) {
            return string.replacingOccurrences(of: "CN¥", with: "¥")
        }
        return "¥\(price)"
    }
    
    /// 格式化日期
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
    
    /// 检查是否有待生效的降级订阅（年卡降级月卡，年卡到期前）
    private func hasPendingDowngradeSubscription() -> Bool {
        // 检查 StoreKit 的 currentEntitlements 中是否有年卡
        // 同时检查本地是否有月卡降级凭证
        guard let currentType = storeManager.activeSubscriptionType else { return false }
        
        // 如果当前是年卡，且用户购买了月卡（降级），则年卡到期前不能再买
        // 实际逻辑：检查是否有两个订阅同时存在（年卡当前生效 + 月卡待生效）
        // StoreKit 会在年卡到期后自动切换，期间不能购买其他订阅
        
        // 简化判断：如果当前有年卡，且本地凭证类型是月卡，说明已降级待生效
        if currentType == .yearly,
           let localTicket = ticketManager.subscriptionTicket,
           localTicket.type == .monthly {
            return true
        }
        return false
    }
    
    /// 判断是否允许跨级切换
    private func canCrossGradeSubscription(to type: ProductType) -> Bool {
        guard let currentType = storeManager.activeSubscriptionType else { return true }
        
        // 相同类型不允许
        if currentType == type { return false }
        
        // 年卡降级月卡后，年卡到期前不允许任何购买
        if hasPendingDowngradeSubscription() { return false }
        
        // 其他情况允许跨级
        return true
    }
}

// MARK: - 圆角扩展
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - 预览
struct PaywallView_Previews: PreviewProvider {
    static var previews: some View {
        PaywallView()
    }
}
