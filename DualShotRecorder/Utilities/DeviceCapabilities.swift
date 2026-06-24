import AVFoundation

/// Detects device capabilities for camera features.
struct DeviceCapabilities {

    /// Whether the device supports AVCaptureMultiCamSession (iPhone XS or newer, iOS 13+)
    static var isMultiCamSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    static var hasUltraWideCamera: Bool { ultraWideCamera != nil }
    static var hasWideCamera: Bool      { wideCamera != nil }
    static var hasFrontCamera: Bool     { frontCamera != nil }
    static var hasTorch: Bool           { wideCamera?.hasTorch ?? false }

    // Cached once at first access — device availability doesn't change at runtime.
    // Avoids repeated system calls when these are accessed during session setup.
    static let wideCamera: AVCaptureDevice? =
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

    static let ultraWideCamera: AVCaptureDevice? =
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)

    /// Standard wide-angle front camera. Used for MultiCam (Front+Back) mode where
    /// port discovery must match the physical device type.
    static let frontCamera: AVCaptureDevice? =
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)

    /// Dedicated ultrawide front camera — present on iPhone 17+ as a separate
    /// physical sensor with dramatically wider FOV than the standard selfie camera.
    static let frontUltraWideCamera: AVCaptureDevice? =
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front)

    /// The best available front camera for single-session (non-MultiCam) use.
    /// Prefers the ultrawide sensor (iPhone 17+) for maximum field of view —
    /// this is what gives the wide selfie look that apps like Plop use.
    /// Falls back to the standard wide-angle front camera on older devices.
    static var bestFrontCamera: AVCaptureDevice? {
        frontUltraWideCamera ?? frontCamera
    }

    static let microphone: AVCaptureDevice? =
        AVCaptureDevice.default(for: .audio)

    /// Finds the best format for a device at the given resolution and frame rate.
    ///
    /// - Parameters:
    ///   - multiCamOnly: When `true`, only considers formats where
    ///     `AVCaptureDevice.Format.isMultiCamSupported == true`. This is **required**
    ///     for `AVCaptureMultiCamSession` — using a non-MultiCam format causes the
    ///     session to fail silently and produce a black screen.
    ///     If the requested resolution/fps isn't available in a MultiCam-compatible
    ///     format, the function falls back to the highest-resolution MultiCam format
    ///     that supports at least 30 fps rather than returning `nil`.
    static func bestFormat(
        for device: AVCaptureDevice,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: FrameRate,
        multiCamOnly: Bool = false
    ) -> (format: AVCaptureDevice.Format, frameRateRange: AVFrameRateRange)? {
        let targetFPS = Float64(frameRate.rawValue)
        let targetLongSide = max(targetWidth, targetHeight)

        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?
        var bestResolutionDiff = Int.max
        var bestFOV: Float = 0

        for format in device.formats {
            // Skip formats that can't be used in AVCaptureMultiCamSession
            if multiCamOnly && !format.isMultiCamSupported { continue }

            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let formatLongSide = Int(max(dimensions.width, dimensions.height))

            // Skip formats that are too small
            guard formatLongSide >= targetLongSide else { continue }

            // Check if this format supports our target frame rate
            for range in format.videoSupportedFrameRateRanges {
                guard range.minFrameRate <= targetFPS && range.maxFrameRate >= targetFPS else {
                    continue
                }

                let diff = formatLongSide - targetLongSide
                let fov  = format.videoFieldOfView

                // Primary sort: smallest resolution overshoot (closest to target).
                // Tiebreaker (single-session only): widest field of view.
                //
                // The front camera on Center Stage iPhones exposes multiple formats
                // at the same pixel dimensions but with different FOV — a cropped
                // "standard selfie" format and a wider "wide selfie" format that uses
                // more of the ultrawide sensor. Without this tiebreaker we'd pick
                // the first matching format which is often the narrower one, producing
                // the zoomed-in look. Preferring the widest FOV gives the same wide
                // field of view that apps like Plop use.
                //
                // Disabled for MultiCam (multiCamOnly = true): on some devices the
                // highest-FOV format at a given resolution cannot be physically rotated
                // by the MultiCam ISP. When .portrait is requested on such a format the
                // system letterboxes the 1920×1080 output into 1080×1920 (small
                // landscape image + black bars) instead of rotating. Using the first
                // qualifying format (no FOV preference) avoids this.
                let isBetter = diff < bestResolutionDiff
                            || (!multiCamOnly && diff == bestResolutionDiff && fov > bestFOV)
                if isBetter {
                    bestResolutionDiff = diff
                    bestFormat = format
                    bestRange  = range
                    bestFOV    = fov
                }
            }
        }

        if let format = bestFormat, let range = bestRange {
            return (format, range)
        }

        // Fallback: if multiCamOnly is set and the exact resolution+fps combo isn't
        // available as a MultiCam format, pick the highest-resolution MultiCam-compatible
        // format that still supports at least 30 fps. This prevents a black-screen failure
        // when the user selects e.g. 4K 60fps in Dual Lens mode on a device that only
        // supports 4K 30fps (or 1080p 60fps) through the MultiCam pipeline.
        if multiCamOnly {
            var fallbackFormat: AVCaptureDevice.Format?
            var fallbackRange: AVFrameRateRange?
            var fallbackLongSide = 0

            for format in device.formats {
                guard format.isMultiCamSupported else { continue }
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let longSide = Int(max(dims.width, dims.height))

                for range in format.videoSupportedFrameRateRanges {
                    guard range.maxFrameRate >= 30 else { continue }
                    if longSide > fallbackLongSide {
                        fallbackLongSide = longSide
                        fallbackFormat = format
                        fallbackRange = range
                    }
                }
            }

            if let format = fallbackFormat, let range = fallbackRange {
                print("DeviceCapabilities: \(device.localizedName) — requested \(targetLongSide)p \(Int(targetFPS))fps not available in MultiCam. Falling back to \(fallbackLongSide)p.")
                return (format, range)
            }
        }

        return nil
    }

    /// Checks if dual-lens mode is fully supported (multi-cam + both cameras present)
    static var isDualLensReady: Bool {
        isMultiCamSupported && hasWideCamera && hasUltraWideCamera
    }
}
