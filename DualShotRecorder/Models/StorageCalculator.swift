import Foundation

final class StorageCalculator: ObservableObject {

    /// Estimated megabytes per minute for a single video stream (H.264)
    static func estimatedMBPerMinute(
        resolution: VideoResolution,
        frameRate: FrameRate,
        bitrate: VideoBitrate = .balanced
    ) -> Double {
        // H.264 1080p 30fps ≈ 20 Mbps — matches RecordingSettings.encoderBitsPerSecond
        let baseBitrate: Double = 20.0

        let resolutionMultiplier: Double
        switch resolution {
        case .hd1080p: resolutionMultiplier = 1.0
        case .uhd4K:   resolutionMultiplier = 4.0
        }

        let fpsMultiplier = Double(frameRate.rawValue) / 30.0
        let effectiveBitrateMbps = baseBitrate * resolutionMultiplier * fpsMultiplier * bitrate.multiplier

        // Mbps * 60 s / 8 bits per byte
        return effectiveBitrateMbps * 60.0 / 8.0
    }

    /// Total MB/min for both streams (portrait + landscape) plus audio
    static func totalMBPerMinute(
        resolution: VideoResolution,
        frameRate: FrameRate,
        bitrate: VideoBitrate = .balanced
    ) -> Double {
        let single = estimatedMBPerMinute(resolution: resolution, frameRate: frameRate, bitrate: bitrate)
        // Audio at 128 kbps AAC ≈ 1 MB/min per stream
        let audioMBPerMin = 1.0
        let streamCount: Double = 2.0   // always portrait + landscape
        return (single * streamCount) + (audioMBPerMin * streamCount)
    }

    /// Available storage on the device in megabytes
    static func availableStorageMB() -> Double {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attributes[.systemFreeSize] as? Int64 {
                return Double(freeSize) / (1024.0 * 1024.0)
            }
        } catch {
            print("StorageCalculator: Failed to get available storage: \(error)")
        }
        return 0
    }

    /// Estimated remaining recording time in minutes
    static func remainingMinutes(
        resolution: VideoResolution,
        frameRate: FrameRate,
        bitrate: VideoBitrate = .balanced
    ) -> Double {
        let available = availableStorageMB()
        let mbPerMin = totalMBPerMinute(resolution: resolution, frameRate: frameRate, bitrate: bitrate)
        guard mbPerMin > 0 else { return 0 }
        let usable = max(available - 500, 0)
        return usable / mbPerMin
    }

    /// Formatted string for remaining time display
    static func formattedRemainingTime(
        resolution: VideoResolution,
        frameRate: FrameRate,
        bitrate: VideoBitrate = .balanced
    ) -> String {
        let minutes = remainingMinutes(resolution: resolution, frameRate: frameRate, bitrate: bitrate)
        if minutes < 1 {
            return "< 1 min left"
        } else if minutes >= 60 {
            let hours = Int(minutes / 60)
            let mins  = Int(minutes) % 60
            return mins > 0 ? "~\(hours)h \(mins)m left" : "~\(hours)h left"
        } else {
            return "~\(Int(minutes))m left"
        }
    }
}
