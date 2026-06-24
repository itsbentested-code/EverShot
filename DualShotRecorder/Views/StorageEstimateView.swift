import SwiftUI

/// Displays real-time storage estimates: MB/min usage and remaining recording time.
struct StorageEstimateView: View {
    @ObservedObject var settings: RecordingSettings

    var body: some View {
        HStack(spacing: 12) {
            // MB per minute
            Label {
                Text("~\(Int(StorageCalculator.totalMBPerMinute(resolution: settings.resolution, frameRate: settings.frameRate, bitrate: settings.bitrate).rounded())) MB/min")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            } icon: {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 14)

            // Remaining time
            Label {
                Text(StorageCalculator.formattedRemainingTime(
                    resolution: settings.resolution,
                    frameRate: settings.frameRate,
                    bitrate: settings.bitrate
                ))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            } icon: {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.5))
        )
    }
}
