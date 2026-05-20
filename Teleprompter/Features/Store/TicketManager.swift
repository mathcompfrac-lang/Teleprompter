import Foundation
import CryptoKit
import UIKit

/// 服务凭证
struct ServiceTicket: Codable {
    /// 凭证ID（唯一）
    let ticketId: String
    /// 用户ID（设备标识）
    let userId: String
    /// 凭证类型（使用统一的 ProductType）
    var type: ProductType
    /// 创建时间
    let createdAt: Date
    /// 过期时间（月卡/年卡）
    var expiresAt: Date?
    /// 剩余次数（次卡）
    var remainingUses: Int?
    /// 服务端签名（防篡改）
    var signature: String

    /// 是否有效
    var isValid: Bool {
        // 检查过期时间
        if let expiresAt = expiresAt {
            guard Date() < expiresAt else { return false }
        }
        // 检查剩余次数
        if let remaining = remainingUses {
            guard remaining > 0 else { return false }
        }
        return true
    }

    /// 使用一次（次卡）
    mutating func consume() -> Bool {
        guard type == .perUse, var remaining = remainingUses, remaining > 0 else {
            return false
        }
        remaining -= 1
        remainingUses = remaining
        return true
    }
}

/// 凭证管理器
@MainActor
final class TicketManager: ObservableObject {
    static let shared = TicketManager()

    // MARK: - Published

    @Published var subscriptionTicket: ServiceTicket?  // 订阅凭证（月卡/年卡）
    @Published var perUseTicket: ServiceTicket?        // 次卡凭证
    @Published var freeUsesRemaining: Int = Constants.maxFreeTrials
    @Published var totalUses: Int = 0

    // MARK: - Private

    private let keychain = KeychainWrapper()
    private let subscriptionTicketKey = "subscription_ticket"
    private let perUseTicketKey = "per_use_ticket"
    private let freeUsesKey = Constants.freeUsesRemainingKey
    private let totalUsesKey = "total_uses_count"
    private let deviceIdKey = "device_identifier"

    // 简单签名密钥（实际应该使用服务端验证）
    private let signKey = "TeleprompterSecretKey2026"

    // MARK: - Init

    private init() {
        loadState()
    }

    // MARK: - Public Methods

    /// 加载状态
    func loadState() {
        // 加载订阅凭证
        if let data = keychain.data(forKey: subscriptionTicketKey),
           let ticket = try? JSONDecoder().decode(ServiceTicket.self, from: data) {
            if verifyTicket(ticket) && ticket.isValid {
                subscriptionTicket = ticket
            } else {
                keychain.delete(key: subscriptionTicketKey)
            }
        }

        // 加载次卡凭证
        if let data = keychain.data(forKey: perUseTicketKey),
           let ticket = try? JSONDecoder().decode(ServiceTicket.self, from: data) {
            if verifyTicket(ticket) && ticket.isValid {
                perUseTicket = ticket
            } else {
                keychain.delete(key: perUseTicketKey)
            }
        }

        // 加载免费次数
        freeUsesRemaining = keychain.integer(forKey: freeUsesKey) ?? Constants.maxFreeTrials
        if freeUsesRemaining < 0 { freeUsesRemaining = 0 }

        // 加载总使用次数
        totalUses = keychain.integer(forKey: totalUsesKey) ?? 0
    }

    /// 保存状态
    func saveState() {
        if let ticket = subscriptionTicket,
           let data = try? JSONEncoder().encode(ticket) {
            keychain.set(data: data, forKey: subscriptionTicketKey)
        } else {
            keychain.delete(key: subscriptionTicketKey)
        }

        if let ticket = perUseTicket,
           let data = try? JSONEncoder().encode(ticket) {
            keychain.set(data: data, forKey: perUseTicketKey)
        } else {
            keychain.delete(key: perUseTicketKey)
        }

        keychain.set(integer: freeUsesRemaining, forKey: freeUsesKey)
        keychain.set(integer: totalUses, forKey: totalUsesKey)
    }

    /// 当前生效的凭证（订阅优先）
    var currentTicket: ServiceTicket? {
        // 优先返回有效的订阅凭证
        if let ticket = subscriptionTicket, ticket.isValid {
            return ticket
        }
        // 其次返回次卡凭证
        if let ticket = perUseTicket, ticket.isValid {
            return ticket
        }
        return nil
    }

    /// 是否有订阅（月卡/年卡）
    var hasSubscription: Bool {
        // 优先检查本地凭证
        if subscriptionTicket?.isValid == true {
            return true
        }
        // 同时检查 StoreKit 购买记录（用户可能在其他设备购买）
        return StoreManager.shared.isPremium
    }

    /// 是否有次卡
    var hasPerUse: Bool {
        perUseTicket?.isValid ?? false
    }

    /// 次卡剩余次数
    var perUseRemaining: Int {
        perUseTicket?.remainingUses ?? 0
    }

    /// 检查是否可以使用功能
    var canUseFeature: Bool {
        // 1. 检查订阅
        if hasSubscription { return true }
        // 2. 检查次卡
        if hasPerUse { return true }
        // 3. 检查免费次数
        return freeUsesRemaining > 0
    }

    /// 使用一次功能
    /// - Returns: 是否成功
    @discardableResult
    func consumeUse() -> Bool {
        // 1. 优先使用订阅（不扣次数）
        if hasSubscription {
            totalUses += 1
            saveState()
            return true
        }

        // 2. 其次使用次卡
        if var ticket = perUseTicket, ticket.isValid {
            if ticket.consume() {
                perUseTicket = ticket
                totalUses += 1
                saveState()
                return true
            }
        }

        // 3. 最后使用免费次数
        if freeUsesRemaining > 0 {
            freeUsesRemaining -= 1
            totalUses += 1
            saveState()
            return true
        }

        return false
    }

    /// 创建次卡凭证
    func createPerUseTicket(uses: Int) -> ServiceTicket {
        let deviceId = getDeviceId()
        let ticketId = UUID().uuidString
        let now = Date()

        var ticket = ServiceTicket(
            ticketId: ticketId,
            userId: deviceId,
            type: .perUse,
            createdAt: now,
            expiresAt: nil,
            remainingUses: uses,
            signature: ""
        )

        ticket.signature = signTicket(ticket)

        // 累加到现有次卡凭证
        if var existing = perUseTicket, existing.isValid {
            existing.remainingUses = (existing.remainingUses ?? 0) + uses
            existing.signature = signTicket(existing)
            perUseTicket = existing
        } else {
            perUseTicket = ticket
        }

        saveState()
        return ticket
    }

    /// 创建订阅凭证（月卡/年卡）
    func createSubscriptionTicket(type: ProductType, duration: Int) -> ServiceTicket {
        let deviceId = getDeviceId()
        let ticketId = UUID().uuidString
        let now = Date()

        var expiresAt: Date?
        if type == .monthly {
            expiresAt = Calendar.current.date(byAdding: .month, value: duration, to: now)
        } else {
            expiresAt = Calendar.current.date(byAdding: .year, value: duration, to: now)
        }

        // 如果已有有效订阅，延长有效期
        if var existing = subscriptionTicket,
           existing.isValid,
           let currentExpiry = existing.expiresAt {
            let baseDate = currentExpiry > now ? currentExpiry : now
            if type == .monthly {
                expiresAt = Calendar.current.date(byAdding: .month, value: duration, to: baseDate)
            } else {
                expiresAt = Calendar.current.date(byAdding: .year, value: duration, to: baseDate)
            }

            // 更新凭证类型（可能跨级切换：月卡→年卡 或 年卡→月卡）
            existing.type = type
            existing.expiresAt = expiresAt
            existing.signature = signTicket(existing)
            subscriptionTicket = existing
            saveState()
            return existing
        }

        // 创建新订阅
        var ticket = ServiceTicket(
            ticketId: ticketId,
            userId: deviceId,
            type: type,
            createdAt: now,
            expiresAt: expiresAt,
            remainingUses: nil,
            signature: ""
        )

        ticket.signature = signTicket(ticket)
        subscriptionTicket = ticket
        saveState()
        return ticket
    }

    /// 添加次卡次数
    func addPerUseTickets(count: Int) {
        _ = createPerUseTicket(uses: count)
    }

    /// 延长订阅
    func extendSubscription(type: ProductType, duration: Int) {
        _ = createSubscriptionTicket(type: type, duration: duration)
    }

    /// 获取使用状态描述
    var statusDescription: String {
        if hasSubscription {
            if let expiry = subscriptionTicket?.expiresAt {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                return "会员剩余 \(days) 天，到期自动续费"
            }
            return "会员有效"
        } else if hasPerUse {
            return "剩余 \(perUseRemaining) 次"
        }
        return "免费剩余 \(freeUsesRemaining) 次"
    }

    // MARK: - Private Methods

    private func getDeviceId() -> String {
        if let id = keychain.string(forKey: deviceIdKey) {
            return id
        }
        let newId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        keychain.set(string: newId, forKey: deviceIdKey)
        return newId
    }

    private func signTicket(_ ticket: ServiceTicket) -> String {
        // 简单签名：HMAC-SHA256
        let data = "\(ticket.ticketId)|\(ticket.userId)|\(ticket.type.rawValue)|\(ticket.createdAt.timeIntervalSince1970)"
        let key = SymmetricKey(data: signKey.data(using: .utf8)!)
        let signature = HMAC<SHA256>.authenticationCode(for: data.data(using: .utf8)!, using: key)
        return Data(signature).base64EncodedString()
    }

    private func verifyTicket(_ ticket: ServiceTicket) -> Bool {
        let expectedSignature = signTicket(ticket)
        return ticket.signature == expectedSignature
    }
}

// MARK: - Keychain 封装

class KeychainWrapper {
    func set(string: String, forKey key: String) {
        if let data = string.data(using: .utf8) {
            set(data: data, forKey: key)
        }
    }

    func set(data: Data, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func set(integer: Int, forKey key: String) {
        var value = integer
        let data = Data(bytes: &value, count: MemoryLayout<Int>.size)
        set(data: data, forKey: key)
    }

    func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }

    func integer(forKey key: String) -> Int? {
        guard let data = data(forKey: key),
              data.count == MemoryLayout<Int>.size else { return nil }
        return data.withUnsafeBytes { $0.load(as: Int.self) }
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
