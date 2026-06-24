import CoreImage
import CoreVideo
import AVFoundation
import Metal

/// Handles cropping and scaling video frames to target aspect ratios.
final class VideoProcessor {

    let ciContext: CIContext
    // Cached once — CGColorSpaceCreateDeviceRGB() is inexpensive but there's
    // no reason to call it on every frame at 30–60 fps.
    private let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: metalDevice, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }

        let ctx = ciContext
        DispatchQueue.global(qos: .userInitiated).async {
            let warmupSize = CGRect(x: 0, y: 0, width: 128, height: 128)
            let warmupImage = CIImage(color: CIColor.black).cropped(to: warmupSize)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 128,
                kCVPixelBufferHeightKey as String: 128,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var warmupBuffer: CVPixelBuffer?
            if CVPixelBufferCreate(kCFAllocatorDefault, 128, 128,
                                   kCVPixelFormatType_32BGRA,
                                   attrs as CFDictionary, &warmupBuffer) == kCVReturnSuccess,
               let buf = warmupBuffer {
                ctx.render(warmupImage, to: buf, bounds: warmupSize,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            }
        }
    }

    // MARK: - Pixel Buffer Pool

    /// Creates a pixel buffer pool for reusing buffers efficiently
    static func createPixelBufferPool(
        width: Int,
        height: Int
    ) -> CVPixelBufferPool? {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        if status != kCVReturnSuccess {
            print("VideoProcessor: Failed to create pixel buffer pool: \(status)")
            return nil
        }
        return pool
    }

    // MARK: - Frame Cropping

    /// Crops and scales a pixel buffer to the target dimensions.
    /// Extracts the largest centered region matching the target aspect ratio,
    /// then scales to the exact target dimensions.
    func cropAndScale(
        pixelBuffer: CVPixelBuffer,
        toWidth targetWidth: Int,
        toHeight targetHeight: Int,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)

        let targetAspect = Double(targetWidth) / Double(targetHeight)
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)

        // Calculate the crop rect (centered) to match the target aspect ratio
        var cropRect: CGRect
        if sourceAspect > targetAspect {
            // Source is wider than target — crop sides
            let cropWidth = Double(sourceHeight) * targetAspect
            let offsetX = (Double(sourceWidth) - cropWidth) / 2.0
            cropRect = CGRect(x: offsetX, y: 0, width: cropWidth, height: Double(sourceHeight))
        } else {
            // Source is taller than target — crop top and bottom
            let cropHeight = Double(sourceWidth) / targetAspect
            let offsetY = (Double(sourceHeight) - cropHeight) / 2.0
            cropRect = CGRect(x: 0, y: offsetY, width: Double(sourceWidth), height: cropHeight)
        }

        // Create CIImage and apply crop + scale
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = ciImage.cropped(to: cropRect)

        // Scale to exact target dimensions
        let scaleX = CGFloat(targetWidth) / cropRect.width
        let scaleY = CGFloat(targetHeight) / cropRect.height
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Render to output pixel buffer
        var outputBuffer: CVPixelBuffer?
        if let pool = pool {
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
            if status != kCVReturnSuccess {
                return nil
            }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                targetWidth,
                targetHeight,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &outputBuffer
            )
            if status != kCVReturnSuccess {
                return nil
            }
        }

        guard let output = outputBuffer else { return nil }

        // Use explicit integer bounds so floating-point precision in the crop/scale
        // math can never leave an unrendered edge strip with garbage pool data.
        // Pinning to DeviceRGB also prevents HDR tone-mapping surprises on devices
        // that capture in a wide-gamut or HLG color space.
        let outputBounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        ciContext.render(scaled, to: output, bounds: outputBounds,
                         colorSpace: deviceRGBColorSpace)
        return output
    }


    /// Crops a pixel buffer to an explicitly-provided rect, then scales to target dimensions.
    func cropAndScale(
        pixelBuffer: CVPixelBuffer,
        cropRect: CGRect,
        toWidth targetWidth: Int,
        toHeight targetHeight: Int,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = ciImage.cropped(to: cropRect)

        let scaleX = CGFloat(targetWidth)  / cropRect.width
        let scaleY = CGFloat(targetHeight) / cropRect.height
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var outputBuffer: CVPixelBuffer?
        if let pool = pool {
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer) == kCVReturnSuccess
            else { return nil }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey           as String: targetWidth,
                kCVPixelBufferHeightKey          as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferCreate(
                kCFAllocatorDefault, targetWidth, targetHeight,
                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer
            ) == kCVReturnSuccess else { return nil }
        }

        guard let output = outputBuffer else { return nil }

        let outputBounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        ciContext.render(scaled, to: output, bounds: outputBounds, colorSpace: deviceRGBColorSpace)
        return output
    }

    // MARK: - Buffer Rotation

    /// Physically rotates a pixel buffer 90° CW (clockwise).
    ///
    /// Used to correct native-landscape front-camera frames (delivered in `.landscapeRight`
    /// orientation with person lying sideways) back to upright portrait orientation.
    /// For a 1920×1080 input the output is 1080×1920.
    func rotatedCW90(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcH   // 90° CW: former height becomes width
        let outH = srcW   // former width becomes height

        // CIImage coordinate space has origin at bottom-left.
        // 90° CW: (x,y) → (y, -x). After rotation all y values are negative
        // (range −srcW … 0). Translate up by srcW to restore positive space.
        let rotatedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(srcW)))

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey           as String: outW,
            kCVPixelBufferHeightKey          as String: outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey  as String: true
        ]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let output = out else { return nil }

        ciContext.render(rotatedImage, to: output,
                         bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                         colorSpace: deviceRGBColorSpace)
        return output
    }

    /// Physically rotates a pixel buffer 90° CCW (counter-clockwise).
    ///
    /// Used to normalise native-landscape camera buffers to portrait orientation
    /// before crop/scale. In AVCaptureMultiCamSession, setting
    /// videoOrientation = .portrait on a connection does not always physically
    /// rotate the pixel data — the ultrawide camera in particular often delivers
    /// its native-landscape (wider-than-tall) buffer regardless of the connection
    /// setting. When that happens the cropAndScale pass-through produces a
    /// landscape video where the scene is rotated 90°. Calling this first ensures
    /// cropAndScale always receives an upright portrait buffer, matching how a
    /// standard single-camera session behaves.
    ///
    /// For a 1920×1080 input the output is 1080×1920.
    /// Returns nil if the CIImage render fails.
    func rotatedCCW90(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        // After 90° CCW the former width becomes the height and vice-versa.
        let outW = srcH
        let outH = srcW

        // CIImage coordinate space has origin at bottom-left.
        // 90° CCW: (x,y) → (−y, x). After the rotation, all x values are
        // negative (range −srcH … 0). Translate right by srcH to put the
        // image back into positive coordinates.
        // Build the rotated CIImage. After 90° CCW rotation all x coords become
        // negative, so translate right by srcH to bring them back to positive space.
        let rotatedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            .transformed(by: CGAffineTransform(translationX: CGFloat(srcH), y: 0))
        // After both transforms the extent is (0, 0, srcH, srcW) = (0, 0, outW, outH). ✓

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey           as String: outW,
            kCVPixelBufferHeightKey          as String: outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey  as String: true
        ]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let output = out else { return nil }

        ciContext.render(rotatedImage, to: output,
                         bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                         colorSpace: deviceRGBColorSpace)
        return output
    }

    // MARK: - Sample Buffer Creation

    /// Creates a new CMSampleBuffer wrapping a processed pixel buffer,
    /// preserving the timing info from the original sample buffer.
    static func createSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        withTimingFrom originalBuffer: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(originalBuffer, at: 0, timingInfoOut: &timingInfo)

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDesc = formatDescription else { return nil }

        var newSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )

        return newSampleBuffer
    }
}
