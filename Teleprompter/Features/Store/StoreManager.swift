import Foundation
import StoreKit
import Combine
import UIKit

/// 产品类型（统一枚举，替代原 SubscriptionType + TicketType）
/// rawValue = StoreKit 产品 ID，同时用于 Keychain 存储
enum ProductType: String, Codable, CaseIterable {
    case perUse = "com.teleprompter.per_use_1"
    case monthly = "com.teleprompter.monthly"
    case yearly = "com.teleprompter.yearly"

    /// 是否为订阅型（月卡/年卡），次卡是消费型
    var isSubscription: Bool {
        self == .monthly || self == .yearly
    }

    var displayName: String {
        switch self {
        case .perUse: return "次卡"
        case .monthly: return "月卡"
        case .yearly: return "年卡"
        }
    }

    var description: String {
        switch self {
        case .perUse: return "买固定次数，用完即止"
        case .monthly: return "按月订阅，自动续费"
        case .yearly: return "按年订阅，自动续费，更优惠"
        }
    }
}

/// 购买状态
enum PurchaseState: Equatable {
    case idle
    case loading
    case purchasing
    case restoring
    case success
    case failed(String)

    static func == (lhs: PurchaseState, rhs: PurchaseState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.purchasing, .purchasing),
             (.restoring, .restoring), (.success, .success):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

/// 内购管理器
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    // MARK: - Published

    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var isPremium = false
    @Published var subscriptionEndDate: Date?
    /// 当前生效的订阅类型（只有月卡/年卡，次卡不会设置此属性）
    @Published var activeSubscriptionType: ProductType?

    /// 记录刚完成购买的产品ID（用于购买成功后确定类型）
    @Published var pendingPurchaseProductID: String?

    // MARK: - Private

    private var updates: Task<Void, Never>?

    // MARK: - Init

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleTransactionResult(result)
            }
        }
    }

    deinit {
        updates?.cancel()
    }

    // MARK: - Public Methods

    /// 加载产品（次卡 + 月卡 + 年卡）
    func loadProducts() async {
        let productIDs: Set<String> = [
            ProductType.perUse.rawValue,
            ProductType.monthly.rawValue,
            ProductType.yearly.rawValue
        ]

        print("[StoreManager] 开始加载产品，IDs: \(productIDs)")
        purchaseState = .loading

        do {
            products = try await Product.products(for: productIDs)
            print("[StoreManager] 加载成功，产品数量: \(products.count)")
            for product in products {
                print("[StoreManager] 产品: \(product.id) - \(product.displayPrice)")
            }

            // 按顺序排列：次卡、年卡、月卡
            products.sort { p1, p2 in
                let order: [String] = [
                    ProductType.perUse.rawValue,
                    ProductType.yearly.rawValue,
                    ProductType.monthly.rawValue
                ]
                guard let i1 = order.firstIndex(of: p1.id),
                      let i2 = order.firstIndex(of: p2.id) else { return false }
                return i1 < i2
            }

            if products.isEmpty {
                purchaseState = .failed("未找到产品，请检查App Store Connect配置")
            } else {
                purchaseState = .idle
            }
        } catch {
            print("[StoreManager] 加载产品失败: \(error)")
            purchaseState = .failed("加载失败: \(error.localizedDescription)")
        }
    }

    /// 重新加载产品（用于错误恢复）
    func reloadProducts() async {
        print("[StoreManager] 重新加载产品...")
        await loadProducts()
    }

    /// 购买产品（支持次卡多数量，使用 StoreKit 1 API）
    func purchase(_ product: Product, quantity: Int = 1) async {
        purchaseState = .purchasing
        pendingPurchaseProductID = nil
        print("[StoreManager] 开始购买产品: \(product.id), 数量: \(quantity)")
        
        // 使用 StoreKit 1 的 SKMutablePayment 支持 quantity
        let actualQuantity = max(1, quantity)
        
        // 对于次卡，使用 StoreKit 1 API 实现多数量购买
        if product.id == ProductType.perUse.rawValue && actualQuantity > 1 {
            await purchaseWithQuantity(product, quantity: actualQuantity)
        } else {
            // 单次购买或订阅，使用 StoreKit 2
            do {
                let result = try await product.purchase()
                await handlePurchaseResult(result)
            } catch {
                print("[StoreManager] 购买失败: \(error)")
                purchaseState = .failed("购买失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 多数量购买（次卡）- 使用 StoreKit 2 的 quantity 选项
    @MainActor
    private func purchaseWithQuantity(_ product: Product, quantity: Int) async {
        print("[StoreManager] 购买次卡 \(quantity) 次（一次交易）")
        
        do {
            // 使用 StoreKit 2 的 quantity 选项
            let purchaseOption = Product.PurchaseOption.quantity(quantity)
            let result = try await product.purchase(options: [purchaseOption])
            
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    pendingPurchaseProductID = product.id
                    purchaseState = .success
                    print("[StoreManager] 成功购买 \(quantity) 次次卡，交易ID: \(transaction.id)")
                } else {
                    purchaseState = .failed("交易验证失败")
                }
            case .userCancelled:
                print("[StoreManager] 用户取消购买")
                purchaseState = .idle
            case .pending:
                print("[StoreManager] 交易等待中（Ask to Buy）")
                purchaseState = .idle
            @unknown default:
                purchaseState = .failed("未知错误")
            }
        } catch {
            print("[StoreManager] 购买失败: \(error)")
            purchaseState = .failed("购买失败: \(error.localizedDescription)")
        }
    }

    /// 恢复购买
    func restorePurchases() async {
        purchaseState = .restoring
        do {
            try await AppStore.sync()
            await checkPurchasedProducts()
            purchaseState = .success
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    /// 从 StoreKit 检查已生效的订阅（用于刷新到期日期和状态）
    func checkPurchasedProducts() async {
        var hasActiveSubscription = false
        var latestEndDate: Date?
        var activeType: ProductType?
        let now = Date()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            // 只处理月卡/年卡订阅，次卡是消费型不在这里处理
            guard let type = ProductType(rawValue: transaction.productID),
                  type.isSubscription else {
                continue
            }

            // 检查订阅是否过期
            if let expiration = transaction.expirationDate {
                // 过期时间必须大于当前时间才视为有效
                guard expiration > now else {
                    continue
                }
                
                hasActiveSubscription = true
                
                // 优先使用当前设置的订阅类型，如果没有则使用 StoreKit 返回的
                if activeType == nil || activeSubscriptionType == type {
                    activeType = type
                }
                
                if latestEndDate == nil || expiration > latestEndDate! {
                    latestEndDate = expiration
                }
            }
        }

        isPremium = hasActiveSubscription
        subscriptionEndDate = latestEndDate
        // 更新 activeSubscriptionType：如果有有效订阅则更新，如果没有则清空
        activeSubscriptionType = activeType
    }
    
    /// 仅更新订阅到期日期（不覆盖 activeSubscriptionType）
    private func updateSubscriptionEndDate() async {
        guard let currentType = activeSubscriptionType else { return }
        let now = Date()
        
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            
            guard let type = ProductType(rawValue: transaction.productID),
                  type == currentType,
                  let expiration = transaction.expirationDate else {
                continue
            }
            
            // 只更新未过期的订阅日期
            guard expiration > now else { continue }
            
            subscriptionEndDate = expiration
            break
        }
    }

    /// 是否可以使用全部功能（已订阅）
    var canUsePremiumFeatures: Bool {
        isPremium
    }

    /// 获取产品（按类型）
    func product(for type: ProductType) -> Product? {
        products.first { $0.id == type.rawValue }
    }

    /// 获取次卡产品
    var perUseProduct: Product? {
        products.first { $0.id == ProductType.perUse.rawValue }
    }

    /// 是否已加载产品
    var isProductsLoaded: Bool {
        !products.isEmpty
    }

    /// 重置购买状态（测试用）
    func resetPurchaseState() async {
        isPremium = false
        subscriptionEndDate = nil
        activeSubscriptionType = nil
        pendingPurchaseProductID = nil
        print("[StoreManager] 已重置购买状态")
    }
    
    // MARK: - Private Methods

    private func handlePurchaseResult(_ result: Product.PurchaseResult, isMultiPurchase: Bool = false) async {
        switch result {
        case .success(let verification):
            if case .verified(let transaction) = verification {
                pendingPurchaseProductID = transaction.productID

                if let type = ProductType(rawValue: transaction.productID) {
                    if type.isSubscription {
                        activeSubscriptionType = type
                        isPremium = true
                        await updateSubscriptionEndDate()
                    }
                }

                await transaction.finish()
                if !isMultiPurchase {
                    purchaseState = .success
                }
                saveLocalState()
            } else {
                purchaseState = .failed("购买验证失败")
            }
        case .userCancelled:
            purchaseState = .idle
        case .pending:
            purchaseState = .idle
        @unknown default:
            purchaseState = .failed("未知错误")
        }
    }

    private func handleTransactionResult(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await checkPurchasedProducts()
    }

    private func saveLocalState() {
        // 状态通过 @Published 自动同步，此处可扩展本地持久化逻辑
    }
}

