import Foundation
import RevenueCat

/// Central owner of EverShot's subscription state, backed by RevenueCat.
///
/// RevenueCat is server-driven: the products, the "pro" entitlement, and the
/// offering (with its packages) are configured in the RevenueCat dashboard.
/// This class fetches the current offering's packages, runs purchases, and
/// tracks whether the user holds the entitlement.
///
/// `isSubscribed` is the single source of truth for whether everything is unlocked.
@MainActor
final class PurchaseManager: ObservableObject {

    // MARK: - Configuration
    // Public SDK key for the App Store app. Safe to ship in the app.
    static let revenueCatAPIKey = "appl_MkbFAhFaqKtnxuAwkbhLXmloYJF"

    // Entitlement identifier — MUST match the entitlement's identifier in the
    // RevenueCat dashboard. RevenueCat auto-created this as "EverShot Cam" (its
    // display name is "pro") and locks the identifier, so we match it here.
    static let entitlementID = "EverShot Cam"

    // App Store product identifiers — must match App Store Connect and the
    // products attached in RevenueCat.
    static let monthlyID    = "com.bentested.EverShotCam.monthly"
    static let yearlyID     = "com.bentested.EverShotCam.yearly"
    static let yearlySaleID = "com.bentested.EverShotCam.yearly.sale"
    // One-time, non-consumable "buy once, own forever" unlock.
    static let lifetimeID   = "com.bentested.EverShotCam.lifetime"

    // MARK: - Published state
    @Published private(set) var packages: [Package] = []
    @Published private(set) var isSubscribed: Bool = false
    // False until we've gotten the first entitlement answer (cached or fetched).
    // The app shows a brief launch splash until this is true so subscribers are
    // never wrongly shown the paywall on cold launch.
    @Published private(set) var hasResolvedEntitlement: Bool = false
    @Published private(set) var isLoadingProducts: Bool = false
    @Published var lastErrorMessage: String?

    private var customerInfoTask: Task<Void, Never>?

    // MARK: - Lifecycle
    init() {
        customerInfoTask = observeCustomerInfo()
        Task {
            await loadOfferings()
            await refreshEntitlements()
        }
    }

    deinit {
        customerInfoTask?.cancel()
    }

    // MARK: - Convenience accessors
    func package(for productID: String) -> Package? {
        packages.first { $0.storeProduct.productIdentifier == productID }
    }
    var monthly: Package?    { package(for: Self.monthlyID) }
    var yearly: Package?     { package(for: Self.yearlyID) }
    var yearlySale: Package? { package(for: Self.yearlySaleID) }
    var lifetime: Package?   { package(for: Self.lifetimeID) }

    /// Localized price string, falling back to a hardcoded value so the paywall
    /// still looks right before the offering loads (or in Xcode Previews).
    func displayPrice(for productID: String, fallback: String) -> String {
        package(for: productID)?.storeProduct.localizedPriceString ?? fallback
    }

    // MARK: - Loading offerings
    func loadOfferings() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let offerings = try await Purchases.shared.offerings()
            if let current = offerings.current {
                self.packages = current.availablePackages
            } else {
                self.packages = offerings.all.values.first?.availablePackages ?? []
            }
        } catch {
            lastErrorMessage = "Couldn't load subscription options. Check your connection and try again."
        }
    }

    // MARK: - Purchase
    /// Returns true only if the purchase completed and the user is now subscribed.
    @discardableResult
    func purchase(_ package: Package) async -> Bool {
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return false }
            updateSubscription(result.customerInfo)
            return isSubscribed
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Restore
    func restore() async {
        do {
            let info = try await Purchases.shared.restorePurchases()
            updateSubscription(info)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Entitlements
    func refreshEntitlements() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            updateSubscription(info)
        } catch {
            // Couldn't reach RevenueCat and no cache — don't hang the launch
            // splash forever; treat as "not subscribed" so the paywall shows.
            hasResolvedEntitlement = true
        }
    }

    private func updateSubscription(_ info: CustomerInfo) {
        isSubscribed = info.entitlements[Self.entitlementID]?.isActive == true
        hasResolvedEntitlement = true
    }

    private func observeCustomerInfo() -> Task<Void, Never> {
        Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.updateSubscription(info)
            }
        }
    }
}
