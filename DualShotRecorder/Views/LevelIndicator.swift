import SwiftUI
import CoreMotion

/// Horizon level indicator styled after Apple's Camera app.
/// Two small horizontal dashes sit in the centre of the viewfinder.
/// The outer dash is fixed; the inner dash shifts vertically with device roll.
/// Both turn yellow when the camera is level.
struct LevelIndicator: View {

    @StateObject private var motion = MotionTracker()

    private let levelThreshold: Double = 1.0  // degrees
    private let maxOffset: CGFloat     = 40   // max vertical shift in points

    private var isLevel: Bool { abs(motion.roll) < levelThreshold }
    private var color: Color  { isLevel ? .yellow : .white }

    /// Vertical offset of the moving dash — clamped to ±maxOffset
    private var offset: CGFloat {
        let pxPerDegree: CGFloat = 2.5
        return CGFloat(max(-Double(maxOffset), min(Double(maxOffset), motion.roll * Double(pxPerDegree))))
    }

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width  / 2
            let cy = geo.size.height / 2

            ZStack {
                // Fixed centre dash (always at exact centre)
                dash()
                    .foregroundColor(.white.opacity(0.55))
                    .position(x: cx, y: cy)

                // Moving dash — shifts vertically with roll
                dash()
                    .foregroundColor(color)
                    .position(x: cx, y: cy + offset)
                    .animation(.easeOut(duration: 0.08), value: offset)
            }
        }
        .allowsHitTesting(false)
    }

    private func dash() -> some View {
        RoundedRectangle(cornerRadius: 1)
            .frame(width: 24, height: 2.5)
    }
}

// MARK: - Motion Tracker

private final class MotionTracker: ObservableObject {
    /// Roll in degrees: 0 = level, positive = right side down, negative = left side down.
    @Published var roll: Double = 0

    private let manager = CMMotionManager()

    init() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let degrees = asin(max(-1, min(1, data.gravity.x))) * (180 / .pi)
            self?.roll = degrees
        }
    }

    deinit { manager.stopDeviceMotionUpdates() }
}
