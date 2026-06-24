import SwiftUI
import UIKit

// MARK: - Teleprompter Overlay

/// Scrolling script overlay. Speed and pause/play controls sit as small white
/// icons in the top-right corner of the translucent box.
///
/// Scrolling is driven by a UIKit CADisplayLink (via TeleprompterScrollView)
/// rather than a SwiftUI Timer+@State loop. This means frame updates go through
/// a direct CALayer frame change rather than SwiftUI's full layout/diff pipeline,
/// so the teleprompter stays smooth even while the recording pipeline is active.
struct TeleprompterView: View {

    let text: String
    @Binding var speed: TeleprompterSpeed

    @State private var isPaused = false

    /// Cycles slow → medium → fast → slow on each tap.
    /// Writes back through the binding so the Settings picker stays in sync.
    private func cycleSpeed() {
        switch speed {
        case .slow:   speed = .medium
        case .medium: speed = .fast
        case .fast:   speed = .slow
        }
    }

    /// Small icon that represents the current speed tier.
    private var speedIcon: String {
        switch speed {
        case .slow:   return "tortoise.fill"
        case .medium: return "figure.walk"
        case .fast:   return "hare.fill"
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {

            // ── Background ────────────────────────────────────────────────────
            Color.black.opacity(0.30)

            // ── Scrolling text (UIKit-backed, no SwiftUI layout per frame) ────
            TeleprompterScrollView(
                text: text.isEmpty
                    ? "No script set. Add your script in Settings → Teleprompter."
                    : text,
                pixelsPerSecond: speed.pixelsPerSecond,
                isPaused: isPaused
            )

            // ── Soft top fade ─────────────────────────────────────────────────
            VStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.30), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 36)
                Spacer()
            }
            .allowsHitTesting(false)

            // ── Top-right controls ────────────────────────────────────────────
            VStack(spacing: 8) {
                // Pause / play
                Button { isPaused.toggle() } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }

                // Speed — tap to cycle slow / medium / fast
                Button { cycleSpeed() } label: {
                    Image(systemName: speedIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.top, 9)
            .padding(.trailing, 12)
        }
        .clipped()
    }
}

// MARK: - UIKit scroll view wrapper

/// Wraps TeleprompterScrollUIView so SwiftUI can embed it.
/// updateUIView forwards only lightweight value changes — no layout triggered.
private struct TeleprompterScrollView: UIViewRepresentable {

    let text: String
    let pixelsPerSecond: Double
    let isPaused: Bool

    func makeUIView(context: Context) -> TeleprompterScrollUIView {
        let view = TeleprompterScrollUIView()
        view.configure(text: text, pixelsPerSecond: pixelsPerSecond)
        return view
    }

    func updateUIView(_ uiView: TeleprompterScrollUIView, context: Context) {
        if uiView.currentText != text {
            uiView.configure(text: text, pixelsPerSecond: pixelsPerSecond)
        } else {
            uiView.setSpeed(pixelsPerSecond)
        }
        uiView.setPaused(isPaused)
    }
}

// MARK: - UIKit scroll engine

/// Drives teleprompter scrolling entirely in UIKit via CADisplayLink.
/// Each display tick updates `label.frame.origin.y` directly — no SwiftUI
/// diffing, no @State publishing, no layout pass needed.
final class TeleprompterScrollUIView: UIView {

    private(set) var currentText: String = ""

    private let label = UILabel()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var scrollOffset: CGFloat = 0      // pixels scrolled from the bottom
    private var pixelsPerSecond: CGFloat = 55
    private var paused = false

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        clipsToBounds = true
        backgroundColor = .clear
        // Display-only — no touches needed. Without this, the UIKit view swallows
        // all taps before the SwiftUI pause/speed buttons above it can receive them.
        isUserInteractionEnabled = false

        label.numberOfLines = 0
        label.textAlignment = .center
        addSubview(label)

        displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Cap at 30 fps — plenty for reading, halves the callback rate vs 60 fps.
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: Configuration

    func configure(text: String, pixelsPerSecond: Double) {
        currentText = text
        self.pixelsPerSecond = CGFloat(pixelsPerSecond)
        scrollOffset = 0

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 7
        paragraphStyle.alignment   = .center

        let shadow = NSShadow()
        shadow.shadowColor      = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowOffset     = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 3

        label.attributedText = NSAttributedString(string: text, attributes: [
            .font            : UIFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor : UIColor.white,
            .paragraphStyle  : paragraphStyle,
            .shadow          : shadow
        ])

        setNeedsLayout()
    }

    func setSpeed(_ pps: Double) {
        pixelsPerSecond = CGFloat(pps)
    }

    func setPaused(_ value: Bool) {
        if value && !paused {
            // Snapshot the current timestamp so dt is 0 on first resumed tick.
            lastTimestamp = CACurrentMediaTime()
        }
        paused = value
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let hPad: CGFloat = 24
        let maxW = max(bounds.width - hPad * 2, 1)
        let labelSize = label.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        label.frame = CGRect(
            x: hPad,
            y: bounds.height - scrollOffset,
            width: maxW,
            height: labelSize.height
        )
    }

    // MARK: Display link tick

    @objc private func tick(_ link: CADisplayLink) {
        guard !paused else {
            lastTimestamp = link.timestamp
            return
        }

        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp

        // Advance scroll position
        scrollOffset += pixelsPerSecond * CGFloat(dt)

        // Loop when the label has fully scrolled off the top
        let totalDistance = bounds.height + label.frame.height
        if scrollOffset >= totalDistance { scrollOffset = 0 }

        // Move the label directly — no layout pass, no SwiftUI involvement
        label.frame.origin.y = bounds.height - scrollOffset
    }
}
