import SwiftUI
import RevenueCat

/// Paywall shown as the final step of onboarding.
///
/// Three options:
///   • Monthly  – subscription, $0.99/mo, 7-day free trial
///   • Yearly   – subscription, $9.99/yr, 7-day free trial (default / most popular)
///   • Lifetime – one-time non-consumable, $14.99, no trial (pay once, own forever)
///
/// `onComplete()` runs once the user unlocks access (subscribes or buys lifetime).
struct PaywallView: View {

    @EnvironmentObject private var purchases: PurchaseManager
    var onComplete: () -> Void

    /// Debug-only: when true the paywall can be closed at any point (Settings preview).
    var isPreview: Bool = false

    @Environment(\.openURL) private var openURL
    private let legalURL = URL(string: "https://www.bentested.com/evershot-legal")!

    private enum Step { case intro, plans }
    @State private var step: Step = .intro
    @State private var selectedID = PurchaseManager.monthlyID
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    // MARK: Prices (localized when the offering loads, else these fallbacks)
    private var monthlyPrice: String  { purchases.displayPrice(for: PurchaseManager.monthlyID,  fallback: "$0.99") }
    private var yearlyPrice: String   { purchases.displayPrice(for: PurchaseManager.yearlyID,   fallback: "$9.99") }
    private var lifetimePrice: String { purchases.displayPrice(for: PurchaseManager.lifetimeID, fallback: "$14.99") }

    private var isLifetimeSelected: Bool { selectedID == PurchaseManager.lifetimeID }

    private var selectedBillingText: String {
        selectedID == PurchaseManager.monthlyID ? "\(monthlyPrice)/month" : "\(yearlyPrice)/year"
    }

    private var billingDate: String {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            Group {
                switch step {
                case .intro: introScreen
                case .plans: plansScreen
                }
            }
            .transition(.opacity)
        }
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(!isPreview)
        .alert("Purchase Unavailable",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Screen 1: Intro
    private var introScreen: some View {
        VStack(spacing: 0) {
            topBar(showBack: false)

            Text("We want you to\ntry EverShot for free.")
                .font(.system(size: 34, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundColor(.black)
                .padding(.top, 24)
                .padding(.horizontal, 24)

            Spacer(minLength: 32)

            VStack(alignment: .leading, spacing: 26) {
                benefitRow(title: "Two Videos, One Take",
                           detail: "Record wide and ultra-wide at the same time — portrait and landscape, ready to post.")
                benefitRow(title: "Built for Creators",
                           detail: "Teleprompter, grid, level, and time-lapse — everything you need to nail the shot.")
                benefitRow(title: "No Watermarks, Full Quality",
                           detail: "Export clean, high-resolution clips with everything unlocked.")
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            fiveStarLaurel
                .padding(.bottom, 24)

            Spacer(minLength: 0)

            noPaymentLabel
            primaryButton(title: "Try for $0.00") {
                withAnimation { step = .plans }
            }
            Text("7-day free trial, or unlock forever with a one-time purchase.")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Screen 2: Plans
    private var plansScreen: some View {
        VStack(spacing: 0) {
            topBar(showBack: true) { withAnimation { step = .intro } }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Text(isLifetimeSelected ? "Own EverShot,\nyours forever." : "Start your 7-day FREE\ntrial to continue.")
                        .font(.system(size: 32, weight: .heavy))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.top, 12)

                    if isLifetimeSelected {
                        VStack(alignment: .leading, spacing: 18) {
                            valueRow(icon: "checkmark.seal.fill", text: "Pay once — no subscription, ever.")
                            valueRow(icon: "infinity", text: "Every feature unlocked, forever.")
                            valueRow(icon: "iphone", text: "Works on your devices with the same Apple ID.")
                        }
                        .padding(.top, 28)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            timelineRow(icon: "lock.open.fill", tint: .orange,
                                        title: "Today",
                                        detail: "Unlock everything — dual-lens recording, teleprompter, and more.",
                                        isLast: false)
                            timelineRow(icon: "crown.fill", tint: .black,
                                        title: "In 7 Days — Billing Starts",
                                        detail: "You'll be charged \(selectedBillingText) on \(billingDate) unless you cancel anytime before.",
                                        isLast: true)
                        }
                        .padding(.top, 28)
                        .padding(.horizontal, 28)
                    }
                }
            }

            planSelector
                .padding(.horizontal, 20)
                .padding(.top, 10)

            if isLifetimeSelected {
                Spacer().frame(height: 14)
            } else {
                noPaymentLabel
                    .padding(.top, 18)
            }

            primaryButton(title: buttonTitle) {
                startPurchase()
            }
            .disabled(isPurchasing)

            purchaseFooter
        }
    }

    private var buttonTitle: String {
        if isPurchasing { return "Please wait…" }
        return isLifetimeSelected ? "Unlock Forever — \(lifetimePrice)" : "Start My 7-Day Free Trial"
    }

    // MARK: - Reusable pieces

    private func topBar(showBack: Bool, backAction: (() -> Void)? = nil) -> some View {
        HStack {
            if showBack {
                Button { backAction?() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(white: 0.6))
                }
            } else if isPreview {
                Button { onComplete() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            Spacer()
            Button { restore() } label: {
                Text("Restore")
                    .font(.system(size: 17))
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func benefitRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.black)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.black)
                Text(detail)
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func valueRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 28)
            Text(text)
                .font(.system(size: 17))
                .foregroundColor(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fiveStarLaurel: some View {
        HStack(spacing: 4) {
            Image(systemName: "laurel.leading")
                .font(.system(size: 40))
                .foregroundColor(Color(white: 0.7))
            ForEach(0..<5, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.orange)
            }
            Image(systemName: "laurel.trailing")
                .font(.system(size: 40))
                .foregroundColor(Color(white: 0.7))
        }
    }

    private func timelineRow(icon: String, tint: Color, title: String, detail: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Circle()
                    .fill(tint)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    )
                if !isLast {
                    Rectangle()
                        .fill(tint.opacity(0.35))
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 18)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Plan selector (vertical list of three)
    private var planSelector: some View {
        VStack(spacing: 10) {
            planRow(id: PurchaseManager.monthlyID, title: "Monthly",
                    price: "\(monthlyPrice)/mo", note: "7-day free trial", badge: "Most Popular")
            planRow(id: PurchaseManager.yearlyID, title: "Yearly",
                    price: "\(yearlyPrice)/yr", note: "7-day free trial", badge: nil)
            planRow(id: PurchaseManager.lifetimeID, title: "Lifetime",
                    price: lifetimePrice, note: "One-time — pay once, own forever", badge: nil)
        }
    }

    private func planRow(id: String, title: String, price: String, note: String?, badge: String?) -> some View {
        let selected = selectedID == id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedID = id }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(selected ? .black : Color(white: 0.75))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.black))
                        }
                    }
                    if let note {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                }

                Spacer(minLength: 8)

                Text(price)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
            }
            .padding(.horizontal, 16)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.black : Color(white: 0.82),
                            lineWidth: selected ? 2.5 : 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var noPaymentLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
            Text("No Payment Due Now")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(.black)
        .padding(.bottom, 12)
    }

    // Apple requires the auto-renew disclosure (for subscriptions) plus functional
    // Terms of Use and Privacy Policy links where the user buys.
    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            Text(isLifetimeSelected
                 ? "One-time purchase of \(lifetimePrice). No subscription and no recurring charges — EverShot is yours forever."
                 : "7 days free, then \(selectedBillingText). Payment is charged to your Apple ID at confirmation. Your subscription renews automatically unless cancelled at least 24 hours before the end of the period; manage or cancel anytime in your Apple ID settings.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            HStack(spacing: 20) {
                Button("Terms of Use") { openURL(legalURL) }
                Button("Privacy Policy") { openURL(legalURL) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(white: 0.5))
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.black))
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Actions
    private func startPurchase() {
        isPurchasing = true
        Task { @MainActor in
            defer { isPurchasing = false }
            let success = await purchases.purchase(productID: selectedID)
            if success {
                onComplete()
            } else if let message = purchases.lastErrorMessage {
                errorMessage = message
            }
        }
    }

    private func restore() {
        Task { @MainActor in
            await purchases.restore()
            if purchases.isSubscribed { onComplete() }
        }
    }
}
