import Foundation
import Observation
import Security
import StoreKit

/// In-app purchase: three free panoramas, then a one-time "Pano 360 Unlimited" unlock
/// (non-consumable, StoreKit 2, verified transactions). Restorable from Settings.
@MainActor
@Observable
final class Store {
    static let unlimitedID = "com.moritzwolf.pano360.unlimited"
    static let freeLimit = 3

    private(set) var product: Product?
    private(set) var isUnlimited = false
    private(set) var freeUsed = FreeQuota.used
    private(set) var isPurchasing = false
    var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
        Task {
            await loadProduct()
            await refreshEntitlements()
        }
    }

    var canCreatePanorama: Bool { isUnlimited || freeUsed < Self.freeLimit }
    var freeRemaining: Int { max(0, Self.freeLimit - freeUsed) }

    /// Price as shown by the App Store for the user's storefront (e.g. "4,99 €").
    var displayPrice: String { product?.displayPrice ?? "4,99 €" }

    func loadProduct() async {
        product = try? await Product.products(for: [Self.unlimitedID]).first
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.unlimitedID, t.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlimited = unlocked
    }

    func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else {
            message = "The App Store is not available right now. Please try again later."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .pending:
                message = "Your purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isUnlimited ? "Your purchase has been restored." : "No previous purchase was found for this Apple Account."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Called after a new panorama was created successfully.
    func recordPanoramaCreated() {
        guard !isUnlimited else { return }
        FreeQuota.used += 1
        freeUsed = FreeQuota.used
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refreshEntitlements()
    }
}

/// Number of free panoramas used, kept in the Keychain so it survives reinstalling the app.
enum FreeQuota {
    private static let service = "com.moritzwolf.pano360"
    private static let account = "freePanoramasUsed"

    static var used: Int {
        get {
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let s = String(data: data, encoding: .utf8), let n = Int(s) else { return 0 }
            return n
        }
        set {
            let data = Data(String(newValue).utf8)
            let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = base
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
