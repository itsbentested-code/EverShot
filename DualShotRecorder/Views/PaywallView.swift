import SwiftUI
import RevenueCat

/// The subscription paywall shown as the final step of onboarding.
///
/// Flow (mirrors the reference design):
///   1. intro      – "We want you to try EverShot for free."   → Try for $0.00
///   2. reminder   – "We'll send you a reminder…"              → Continue for FREE
///   3. plans      – "Start your 7-day FREE trial to continue" → triggers the
///                    native Apple purchase sheet
///   4. lastDitch  – shown if the user cancels: a one-time discounted offer
///
/// `onComplete()` is called once the user has subscribed (or, while
/// `hardPaywall` is false, once they've exhausted the flow) so the caller can
/// dismiss the paywall and enter the app.
struct PaywallView: View {

    @EnvironmentObject private var purchases: PurchaseManager
    var onComplete: () -> Void

    @Environment(\.openURL) private var openURL
    private let legalURL = URL(string: "https://www.bentested.com/evershot-legal")!

    // MARK: Ship switch
    // While false, closing the last-ditch offer lets the user into the app
    // (handy for testing the rest of the app). Flip to true to make EverShot a
    // true hard paywall — the user cannot enter until they subscribe.
    private let hardPaywall = true

    private enum Step { case intro, reminder, plans, lastDitch }
    @State private var step: Step = .intro
    @State private var selectedID = PurchaseManager.yearlyID
    @State private var isPurchasing = false

    // MARK: Prices (localized when products load, else these fallbacks)
    private var monthlyPrice: String { purchases.displayPrice(for: PurchaseManager.monthlyID, fallback: "$0.99") }
    private var yearlyPrice: String  { purchases.displayPrice(for: PurchaseManager.yearlyID, fallback: "$9.99") }
    private var salePrice: String    { purchases.displayPrice(for: PurchaseManager.yearlySaleID, fallback: "$7.99") }

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
                case .intro:     introScreen
                case .reminder:  reminderScreen
                case .plans:     plansScreen
                case .lastDitch: lastDitchScreen
                }
            }
            .transition(.opacity)
        }
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(true)
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
                withAnimation { step = .reminder }
            }
            trialCaption
        }
    }

    // MARK: - Screen 2: Reminder
    private var reminderScreen: some View {
        VStack(spacing: 0) {
            topBar(showBack: true) { withAnimation { step = .intro } }

            Spacer()

            Text("We'll send you\na reminder before your\nfree trial ends")
                .font(.system(size: 30, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundColor(.black)
                .padding(.horizontal, 24)

            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 108))
                    .foregroundColor(Color(white: 0.85))
                Text("1")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.red))
                    .offset(x: 18, y: -8)
            }
            .padding(.top, 60)

            Spacer()
            Spacer()

            noPaymentLabel
            primaryButton(title: "Continue for FREE") {
                withAnimation { step = .plans }
            }
            trialCaption
        }
    }

    // MARK: - Screen 3: Plans
    private var plansScreen: some View {
        VStack(spacing: 0) {
            topBar(showBack: true) { withAnimation { step = .reminder } }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Text("Start your 7-day FREE\ntrial to continue.")
                        .font(.system(size: 32, weight: .heavy))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.top, 12)

                    VStack(spacing: 0) {
                        timelineRow(icon: "lock.open.fill", tint: .orange,
                                    title: "Today",
                                    detail: "Unlock everything — dual-lens recording, teleprompter, and more.",
                                    isLast: false)
                        timelineRow(icon: "bell.fill", tint: .orange,
                                    title: "In 5 Days — Reminder",
                                    detail: "We'll send you a reminder that your trial is ending soon.",
                                    isLast: false)
                        timelineRow(icon: "crown.fill", tint: .black,
                                    title: "In 7 Days — Billing Starts",
                                    detail: "You'll be charged on \(billingDate) unless you cancel anytime before.",
                                    isLast: true)
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 28)
                }
            }

            planSelector
                .padding(.horizontal, 20)
                .padding(.top, 8)

            noPaymentLabel
                .padding(.top, 20)
            primaryButton(title: isPurchasing ? "Please wait…" : "Start My 7-Day Free Trial") {
                startTrial()
            }
            .disabled(isPurchasing)
            purchaseFooter
        }
    }

    // MARK: - Screen 4: Last-ditch offer
    private var lastDitchScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if hardPaywall { withAnimation { step = .plans } }
                    else { onComplete() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            Text("Your one-time offer")
                .font(.system(size: 34, weight: .heavy))
                .foregroundColor(.black)

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 180, height: 108)
                Text("20% OFF\nFOREVER")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            HStack(spacing: 10) {
                Text(yearlyPrice)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.black)
                    .strikethrough()
                Text("\(salePrice)/yr")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.black)
            }
            .padding(.top, 24)

            Text("Once you close this one-time offer, it's gone!")
                .font(.system(size: 15))
                .foregroundColor(.gray)
                .padding(.top, 16)

            Spacer()

            saleCard
                .padding(.horizontal, 20)

            primaryButton(title: isPurchasing ? "Please wait…" : "Start Free Trial") {
                startSaleTrial()
            }
            .disabled(isPurchasing)

            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text("No Commitment — Cancel Anytime")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.black)
            .padding(.top, 16)
            .padding(.bottom, 10)

            purchaseFooter
        }
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

    private var planSelector: some View {
        HStack(spacing: 12) {
            planCard(id: PurchaseManager.monthlyID,
                     title: "Monthly",
                     price: "\(monthlyPrice)/mo",
                     badge: nil)
            planCard(id: PurchaseManager.yearlyID,
                     title: "Yearly",
                     price: "\(yearlyPrice)/yr",
                     badge: "Most Popular")
        }
    }

    private func planCard(id: String, title: String, price: String, badge: String?) -> some View {
        let selected = selectedID == id
        return Button {
            selectedID = id
        } label: {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.black : Color(white: 0.8),
                            lineWidth: selected ? 2.5 : 1.5)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.black)
                        Text(price)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.black)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(selected ? .black : Color(white: 0.7))
                }
                .padding(16)

                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black))
                        .offset(y: -12)
                }
            }
            .frame(height: 88)
        }
        .buttonStyle(.plain)
    }

    private var saleCard: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yearly Plan")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                    Text("12 mo • \(salePrice)")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                Spacer()
                Text("\(salePrice)/yr")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.black)
            }
            .padding(16)

            Text("7-DAY FREE TRIAL")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black))
                .offset(y: -12)
        }
        .frame(height: 88)
        .padding(.bottom, 12)
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

    private var trialCaption: some View {
        Text("7 days free, then \(monthlyPrice)/month")
            .font(.system(size: 14))
            .foregroundColor(.gray)
            .padding(.top, 12)
            .padding(.bottom, 24)
    }

    // Shown on the purchase screens. Apple requires the auto-renew disclosure
    // plus functional Terms of Use and Privacy Policy links where the user buys.
    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            Text("7 days free, then \(monthlyPrice)/month. Payment is charged to your Apple ID at confirmation. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period; manage or cancel anytime in your Apple ID settings.")
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
    private var selectedPackage: Package? {
        purchases.package(for: selectedID)
    }

    private func startTrial() {
        isPurchasing = true
        Task { @MainActor in
            defer { isPurchasing = false }
            guard let package = selectedPackage else {
                // Offering not loaded yet (e.g. RevenueCat products not configured) —
                // fall through to the last-ditch offer so the flow is still testable.
                withAnimation { step = .lastDitch }
                return
            }
            let success = await purchases.purchase(package)
            if success {
                onComplete()
            } else {
                withAnimation { step = .lastDitch }
            }
        }
    }

    private func startSaleTrial() {
        isPurchasing = true
        Task { @MainActor in
            defer { isPurchasing = false }
            guard let package = purchases.yearlySale ?? purchases.yearly else {
                if !hardPaywall { onComplete() }
                return
            }
            let success = await purchases.purchase(package)
            if success || !hardPaywall {
                onComplete()
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
