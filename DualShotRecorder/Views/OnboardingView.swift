import SwiftUI

// MARK: - Onboarding Page Model

private struct OnboardingPage {
    let icon: String          // SF Symbol name
    let iconColor: Color
    let title: String
    let subtitle: String
    let bullets: [BulletItem]

    struct BulletItem {
        let icon: String
        let text: String
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        // Page 1 — Welcome
        OnboardingPage(
            icon: "camera.aperture",
            iconColor: .white,
            title: "Welcome to EverShot",
            subtitle: "The camera app that records portrait and landscape video at the exact same time.",
            bullets: [
                .init(icon: "video.fill",         text: "One recording session, two ready-to-post videos"),
                .init(icon: "arrow.up.and.down",  text: "9:16 portrait for TikTok & Reels"),
                .init(icon: "arrow.left.and.right", text: "16:9 landscape for YouTube & beyond"),
            ]
        ),
        // Page 2 — Dual Lens
        OnboardingPage(
            icon: "camera.on.rectangle.fill",
            iconColor: .yellow,
            title: "Two Cameras, One Take",
            subtitle: "EverShot Cam uses both rear cameras simultaneously so every angle is covered.",
            bullets: [
                .init(icon: "1.circle.fill",      text: "Wide (1×) records your portrait clip"),
                .init(icon: "2.circle.fill",       text: "Ultra-wide (0.5×) records your landscape clip"),
                .init(icon: "arrow.triangle.2.circlepath", text: "Swap lens assignments anytime in Settings"),
            ]
        ),
        // Page 3 — Features
        OnboardingPage(
            icon: "slider.horizontal.3",
            iconColor: .white,
            title: "Built for Creators",
            subtitle: "Everything you need, nothing you don't.",
            bullets: [
                .init(icon: "grid",               text: "Rule-of-thirds grid overlay to nail your framing"),
                .init(icon: "level",              text: "Horizon level so your shots are always straight"),
                .init(icon: "timer",              text: "Time-lapse mode for cinematic speed ramps"),
                .init(icon: "text.alignleft",     text: "Built-in teleprompter so you never lose your place on camera"),
                .init(icon: "camera.rotate.fill", text: "Switch to front camera for selfie-style dual recording"),
            ]
        ),
        // Page 4 — Ready
        OnboardingPage(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            title: "You're All Set",
            subtitle: "Grant camera, microphone, and photo library access when prompted — EverShot Cam needs these to record and save your videos.",
            bullets: [
                .init(icon: "camera.fill",        text: "Camera — to capture video"),
                .init(icon: "mic.fill",           text: "Microphone — to record audio"),
                .init(icon: "photo.fill",         text: "Photos — to save your clips"),
            ]
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page indicator dots
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Color.white : Color.white.opacity(0.3))
                            .frame(width: i == currentPage ? 20 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.25), value: currentPage)
                    }
                }
                .padding(.top, 60)

                Spacer()

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        pageView(pages[i])
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)

                Spacer()

                // Navigation buttons
                HStack {
                    // Back button
                    if currentPage > 0 {
                        Button {
                            withAnimation { currentPage -= 1 }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 90, height: 50)
                        }
                    } else {
                        Spacer().frame(width: 90)
                    }

                    Spacer()

                    // Next / Finish button
                    Button {
                        if currentPage < pages.count - 1 {
                            withAnimation { currentPage += 1 }
                        } else {
                            // Finished the intro — the app root now shows the paywall
                            // (gated on subscription state).
                            hasCompletedOnboarding = true
                        }
                    } label: {
                        Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(width: currentPage < pages.count - 1 ? 90 : 140, height: 50)
                            .background(Capsule().fill(Color.white))
                            .animation(.easeInOut(duration: 0.2), value: currentPage)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 50)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Page View

    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 0) {
            // Icon
            Image(systemName: page.icon)
                .font(.system(size: 64, weight: .thin))
                .foregroundColor(page.iconColor)
                .padding(.bottom, 32)

            // Title
            Text(page.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            // Subtitle
            Text(page.subtitle)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)
                .padding(.bottom, 36)

            // Bullet items
            VStack(alignment: .leading, spacing: 18) {
                ForEach(page.bullets.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: page.bullets[i].icon)
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 26)
                        Text(page.bullets[i].text)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 40)
        }
        .padding(.horizontal, 8)
    }
}
