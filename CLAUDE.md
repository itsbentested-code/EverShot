# EverShot (DualShotRecorder) — Project Context

## What This App Does
EverShot is an iOS camera app that simultaneously records **two video files** from a single recording session:
- A **portrait (9:16)** video
- A **landscape (16:9)** video

It supports several modes:
- **Dual Lens (Rear)** — ultrawide + wide rear cameras via `AVCaptureMultiCamSession`
- **Dual Lens (Front)** — front camera only via `AVCaptureSession` (single sensor, two crops)
- **Single Lens** — wide rear camera only, two crops from one feed
- **Front + Back** — simultaneous front and rear via `AVCaptureMultiCamSession`

## Current Problem Being Solved

### Primary Issue: Front Camera FOV Too Narrow
In "Dual" mode with the front (selfie) camera, EverShot shows a **zoomed-in / cropped** view compared to apps like **Plop**, which show a dramatically wider field of view. The user wants:
1. The main preview to show the full wide-angle ultrawide view from the front camera
2. The PiP thumbnail to show a landscape-oriented view with the person upright
3. The exported landscape video to reflect the same wide FOV

### Root Cause (Confirmed via device diagnostics)
On iPhone 17+, the front camera system includes **two separate physical sensors**:
- `.builtInWideAngleCamera` at front position → "Front Camera" — 73.2° FOV (standard selfie)
- `.builtInUltraWideCamera` at front position → "Front Ultra Wide Camera" — much wider FOV

EverShot was using `.builtInWideAngleCamera` (73.2°). Plop uses `.builtInUltraWideCamera`. That single wrong device selection was the entire zoom/crop difference.

All formats on `.builtInWideAngleCamera` front report the same 73.2° FOV at every resolution — there is no "wide selfie" format variant on this device. The fix had to be switching to a different physical camera, not a different format.

A second issue: the PiP was generated from the **portrait output** frames, which are a vertical center-crop of the ultrawide sensor (inherently narrower horizontal FOV). The landscape output (`.landscapeRight` connection) captures the full sensor width — a wider FOV — and is the correct source for the PiP.

### Fixes Applied (May Not Be Tested Yet — User Should Build and Test)

**1. `DeviceCapabilities.swift` — `bestFormat()` FOV tiebreaker**
Among formats with the same resolution match, now prefers the highest `videoFieldOfView`. Selects the "wide selfie" format instead of "standard selfie."

**2. `SingleLensRecorder.swift` — PiP from landscape output**
PiP is now generated from the native landscape output frames (full sensor width, widest FOV):
- Landscape frame (1920×1080) delivered with person's head on the RIGHT
- Rotate CCW90 (`.pi/2`) to make person upright → portrait-shaped 1080×1920
- Crop center 16:9 strip → 1080×608 landscape thumbnail

**3. `CameraManager.swift` — diagnostic log**
Added log: `📷 CameraManager: TrueDepth Camera → 1920×1080 @ 30fps, FOV=85.3°`
Check the Xcode console after building. If FOV is now higher than before (~50° → ~85°+), the format fix is working.

### If the PiP Person Appears Upside-Down
The CCW90 rotation direction may be wrong. Try swapping to CW90 (`-.pi/2`) in `SingleLensRecorder.captureOutput` in the `nativeLandscapeOutput` branch. The person's head direction in the raw `.landscapeRight` frames depends on the device/iOS version.

---

## Architecture Overview

### Key Files

| File | Purpose |
|------|---------|
| `Camera/CameraManager.swift` | Central session manager. Handles all `AVCaptureSession` setup, mode switching, recording control. |
| `Camera/SingleLensRecorder.swift` | Records portrait + landscape from ONE camera (front camera mode, or rear wide-only mode). |
| `Camera/DualLensRecorder.swift` | Records portrait + landscape from TWO rear cameras (wide + ultrawide MultiCam). |
| `Camera/FrontBackRecorder.swift` | Records two portrait videos simultaneously (front + rear MultiCam). |
| `Camera/VideoProcessor.swift` | CIImage-based crop/scale/rotate operations. Has `cropAndScale()`, `rotatedCW90()`, `rotatedCCW90()`. |
| `Camera/AudioManager.swift` | Microphone input setup and audio buffer routing. |
| `Utilities/DeviceCapabilities.swift` | Camera device discovery and `bestFormat()` selection. |
| `Models/RecordingSettings.swift` | All user-configurable settings (resolution, fps, mode, etc.). |

### Session Modes (in CameraManager)
- `configureDualLensSession()` → `AVCaptureMultiCamSession`, wide + ultrawide rear
- `configureFrontCameraSession()` → `AVCaptureSession`, front camera with two outputs (portrait + landscape)
- `configureWideOnlySession()` → `AVCaptureSession`, wide rear camera only
- `configureFrontBackSession()` → `AVCaptureMultiCamSession`, front + rear simultaneously

### Front Camera Session Details (`configureFrontCameraSession`)
- Uses `DeviceCapabilities.frontCamera` = `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)`
- Two outputs added to the session:
  - `videoOutput` — portrait connection (`.portrait`), feeds `SingleLensRecorder`
  - `landscapeOutput` — landscape connection (`.landscapeRight`, `isVideoMirrored = false`), feeds `SingleLensRecorder.setNativeLandscapeOutput()`
- Center Stage disabled: `AVCaptureDevice.isCenterStageEnabled = false`
- Zoom reset: `frontDevice.videoZoomFactor = frontDevice.minAvailableVideoZoomFactor`
- `onPreviewFrame` callback → `pipModel.snapshot` → SwiftUI PiP thumbnail

### Landscape Video Pipeline (Front Camera)
```
.landscapeRight frames (1920×1080, head on RIGHT)
    ↓ processNativeLandscapeFrame()
    ↓ cropAndScale() to landscapeDimensions
    ↓ AVAssetWriter with transform = CGAffineTransform(rotationAngle: .pi / 2)   ← CCW90 display transform
→  Landscape .mov file (stored as 1920×1080, player rotates CCW90 on playback → person upright)
```

### PiP Pipeline (Front Camera, after latest fix)
```
.landscapeRight frames (1920×1080, head on RIGHT)
    ↓ CIImage rotate CCW90 → 1080×1920 portrait (person upright)
    ↓ crop center 16:9 strip → 1080×608
    ↓ scale to 621px wide
    ↓ CGImage → pipModel.snapshot → SwiftUI image view
→  Landscape-shaped PiP thumbnail with person upright
```

---

## What Has Been Tried and Failed

| Attempt | Why It Failed |
|---------|--------------|
| `videoZoomFactor = minAvailableVideoZoomFactor` alone | Zoom was already 1.0; the FORMAT was the problem, not zoom |
| Pixel rotation (`rotatedCW90`) on landscape frames | Caused upside-down result or introduced zoom artifacts |
| Writer CCW90 + pixel rotation on landscape frames | Conflicting transforms caused wrong orientation |
| PiP from portrait frames with 16:9 crop | Portrait output has narrower FOV than landscape output |
| `lVideoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)` alone | Correct for file playback, but didn't fix PiP or preview |

---

## Format Selection (bestFormat)
Located in `DeviceCapabilities.bestFormat()`. Strategy:
1. Filter formats: `formatLongSide >= targetLongSide` AND supports target fps (AND `isMultiCamSupported` when needed)
2. Primary sort: **smallest** `formatLongSide - targetLongSide` (pick format closest to target resolution)
3. Tiebreaker (added in latest fix): **highest** `videoFieldOfView` among same-resolution formats
4. Fallback for MultiCam: if no exact match, pick highest-resolution MultiCam-compatible format at ≥30fps

---

## Settings & Enums

```swift
// RecordingSettings key properties
var resolution: VideoResolution      // ._1080p, ._4K, etc.
var frameRate: FrameRate             // ._30, ._60
var dualLensUseFrontCamera: Bool     // true = front camera dual mode
var isSingleLensMode: Bool           // true = rear wide only
var isFrontBackMode: Bool            // true = simultaneous front+rear
var cameraAssignment: CameraAssignment  // which camera → portrait vs landscape
var appleLog: Bool                   // Apple Log color space (iOS 17+)
var fileFormat: FileFormat           // .mov or .mp4
var isTimelapse: Bool
var timelapseSpeed: TimelapseSpeed

// VideoResolution dimensions
resolution.portraitDimensions  // e.g. (1080, 1920)
resolution.landscapeDimensions // e.g. (1920, 1080)
resolution.longSide            // e.g. 1920
resolution.shortSide           // e.g. 1080
```

---

## Known Patterns and Gotchas

- **Lead frame skip**: `kLeadingFrameSkipCount = 5` — first 5 frames are dropped to let AEC stabilize before recording starts.
- **EIS disabled**: Video stabilization is explicitly turned off (`preferredVideoStabilizationMode = .off`) on all connections. With EIS on, the stabilizer delays first frame delivery by ~1 second causing audio sync issues.
- **Pause offset**: Uses wall-clock time (`CACurrentMediaTime()`) to calculate pause duration and subtract from presentation timestamps.
- **MultiCam formats**: `isMultiCamSupported` must be true for all formats used in `AVCaptureMultiCamSession`. Non-multiCam formats cause silent black-screen failures.
- **Session preset**: `configureFrontCameraSession` sets `.high` as initial preset, but `configureDevice()` overrides `device.activeFormat` which changes preset to `.inputPriority` automatically.
- **Preview mirroring**: Preview layer is mirrored (`isVideoMirrored = true`) for natural selfie feel. Recording outputs are NOT mirrored (`isVideoMirrored = false`).
- **FrontCameraPipModel**: Separate `ObservableObject` for PiP frames so only the PiP subview re-renders when a new frame arrives, not all of `RecordingView`.

---

## Pending / Next Steps

1. **Build and test the format + PiP fix** — user should run on device, check Xcode console for FOV log, compare main preview to Plop app
2. **If PiP person is upside-down** — swap CCW90 to CW90 in `captureOutput` landscape branch (change `.pi/2` to `-.pi/2` and adjust translation)
3. **Verify exported landscape video** — make sure the landscape .mov plays back with person upright (the `.pi/2` writer transform handles this)
4. **Consider `builtInUltraWideCamera` at front position** — on iPhone 17+, there's a dedicated ultrawide front camera. `DeviceCapabilities.frontCamera` currently always requests `.builtInWideAngleCamera`. For iPhone 17+, switching to `.builtInUltraWideCamera` at front position would give even wider FOV. Not yet implemented.
