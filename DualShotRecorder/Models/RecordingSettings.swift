import Foundation
import AVFoundation

// MARK: - Video Resolution

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd1080p = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }

    var portraitDimensions: (width: Int, height: Int) {
        switch self {
        case .hd1080p: return (1080, 1920)
        case .uhd4K: return (2160, 3840)
        }
    }

    var landscapeDimensions: (width: Int, height: Int) {
        switch self {
        case .hd1080p: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }

    var shortSide: Int {
        switch self {
        case .hd1080p: return 1080
        case .uhd4K: return 2160
        }
    }

    var longSide: Int {
        switch self {
        case .hd1080p: return 1920
        case .uhd4K: return 3840
        }
    }
}

// MARK: - Frame Rate

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String { "\(rawValue) fps" }

    var cmTime: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }
}

// MARK: - File Format

enum FileFormat: String, CaseIterable, Identifiable {
    case mov = "MOV"
    case mp4 = "MP4"

    var id: String { rawValue }

    var fileExtension: String { rawValue.lowercased() }

    var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }

    var videoCodec: AVVideoCodecType {
        // Both formats use H.264 — compatible with all editing apps and platforms.
        return .h264
    }
}

// MARK: - Camera Assignment

enum CameraAssignment: String, CaseIterable, Identifiable {
    case widePortrait = "Wide → Portrait"
    case wideLeftLandscape = "Wide → Landscape"

    var id: String { rawValue }

    var wideIsPortrait: Bool { self == .widePortrait }

    var displayDescription: String {
        switch self {
        case .widePortrait:      return "Wide (1x) = Portrait, Ultra-Wide (0.5x) = Landscape"
        case .wideLeftLandscape: return "Wide (1x) = Landscape, Ultra-Wide (0.5x) = Portrait"
        }
    }
}

// MARK: - Timelapse Speed

enum TimelapseSpeed: Int, CaseIterable, Identifiable {
    case twoX    = 2
    case fiveX   = 5
    case tenX    = 10
    case thirtyX = 30

    var id: Int { rawValue }
    var displayName: String { "\(rawValue)×" }
    var skipInterval: Int { rawValue }
}

// MARK: - Teleprompter Speed

enum TeleprompterSpeed: String, CaseIterable, Identifiable {
    case slow   = "Slow"
    case medium = "Medium"
    case fast   = "Fast"

    var id: String { rawValue }

    var pixelsPerSecond: Double {
        switch self {
        case .slow:   return 25
        case .medium: return 55
        case .fast:   return 100
        }
    }
}

// MARK: - Video Bitrate

enum VideoBitrate: String, CaseIterable, Identifiable {
    case low      = "Low"
    case balanced = "Balanced"
    case high     = "High"

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .low:      return 0.6
        case .balanced: return 1.0
        case .high:     return 1.6
        }
    }
}

// MARK: - Torch Mode

enum TorchMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case on  = "On"

    var id: String { rawValue }

    var avTorchMode: AVCaptureDevice.TorchMode {
        switch self {
        case .off: return .off
        case .on:  return .on
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .on:  return "bolt.fill"
        }
    }
}

// MARK: - Recording Settings

final class RecordingSettings: ObservableObject {

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let savePreferences     = "evershot.savePreferences"
        static let resolution          = "evershot.resolution"
        static let frameRate           = "evershot.frameRate"
        static let bitrate             = "evershot.bitrate"
        static let appleLog            = "evershot.appleLog"
        static let isTimelapse         = "evershot.isTimelapse"
        static let timelapseSpeed      = "evershot.timelapseSpeed"
        static let cameraAssignment    = "evershot.cameraAssignment"
        static let dualLensUseFrontCamera = "evershot.dualLensUseFrontCamera"
        static let isSingleLensMode    = "evershot.isSingleLensMode"
        static let isFrontBackMode     = "evershot.isFrontBackMode"
        static let showGrid            = "evershot.showGrid"
        static let showLevel           = "evershot.showLevel"
        static let showTeleprompter    = "evershot.showTeleprompter"
        static let teleprompterText    = "evershot.teleprompterText"
        static let teleprompterSpeed   = "evershot.teleprompterSpeed"
        static let thumbnailX          = "evershot.thumbnailX"
        static let thumbnailY          = "evershot.thumbnailY"
    }

    // MARK: - Save Preferences Toggle
    //
    // When OFF (default): all settings reset to defaults on each launch.
    // When ON:            all settings are persisted and restored on launch.
    // The toggle itself is ALWAYS persisted so the user's choice survives relaunches.

    @Published var savePreferences: Bool {
        didSet {
            UserDefaults.standard.set(savePreferences, forKey: Keys.savePreferences)
            if savePreferences {
                // Immediately persist the current in-session values so the very next
                // launch loads what the user has set, not stale/empty UserDefaults.
                saveAllSettings()
            }
        }
    }

    // MARK: - Persisted Settings

    /// All videos are saved as MP4 (H.264). Not user-configurable.
    let fileFormat: FileFormat = .mp4

    @Published var resolution: VideoResolution {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(resolution.rawValue, forKey: Keys.resolution) }
    }
    @Published var frameRate: FrameRate {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(frameRate.rawValue, forKey: Keys.frameRate) }
    }
    @Published var bitrate: VideoBitrate {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(bitrate.rawValue, forKey: Keys.bitrate) }
    }
    @Published var appleLog: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(appleLog, forKey: Keys.appleLog) }
    }
    @Published var isTimelapse: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(isTimelapse, forKey: Keys.isTimelapse) }
    }
    @Published var timelapseSpeed: TimelapseSpeed {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(timelapseSpeed.rawValue, forKey: Keys.timelapseSpeed) }
    }
    @Published var cameraAssignment: CameraAssignment {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(cameraAssignment.rawValue, forKey: Keys.cameraAssignment) }
    }
    /// Whether the current session has swapped to front camera in Dual/Single modes.
    /// Intentionally NOT persisted — always starts on rear camera each launch so the
    /// app never opens in an unexpected "front cam" state.
    @Published var dualLensUseFrontCamera: Bool = false

    /// Torch intentionally not persisted — always starts off for safety.
    @Published var torchMode: TorchMode = .off

    @Published var showGrid: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(showGrid, forKey: Keys.showGrid) }
    }
    @Published var showLevel: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(showLevel, forKey: Keys.showLevel) }
    }
    @Published var showTeleprompter: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(showTeleprompter, forKey: Keys.showTeleprompter) }
    }

    /// The script text is ALWAYS persisted regardless of savePreferences —
    /// it's content the user typed, not a preference, and losing it would be frustrating.
    @Published var teleprompterText: String {
        didSet { RecordingSettings.saveScript(teleprompterText) }
    }

    @Published var teleprompterSpeed: TeleprompterSpeed {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(teleprompterSpeed.rawValue, forKey: Keys.teleprompterSpeed) }
    }

    @Published var isSingleLensMode: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(isSingleLensMode, forKey: Keys.isSingleLensMode) }
    }

    @Published var isFrontBackMode: Bool {
        didSet { guard savePreferences else { return }
            UserDefaults.standard.set(isFrontBackMode, forKey: Keys.isFrontBackMode) }
    }

    // MARK: - Thumbnail Position
    //
    // Stored as two separate doubles. nil means "use default position".
    // Only written when savePreferences is on.

    var savedThumbnailPosition: CGPoint? {
        get {
            let ud = UserDefaults.standard
            guard ud.object(forKey: Keys.thumbnailX) != nil else { return nil }
            return CGPoint(x: ud.double(forKey: Keys.thumbnailX),
                           y: ud.double(forKey: Keys.thumbnailY))
        }
        set {
            guard savePreferences else { return }
            if let pos = newValue {
                UserDefaults.standard.set(pos.x, forKey: Keys.thumbnailX)
                UserDefaults.standard.set(pos.y, forKey: Keys.thumbnailY)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.thumbnailX)
                UserDefaults.standard.removeObject(forKey: Keys.thumbnailY)
            }
        }
    }

    // MARK: - Script File Storage

    private static var scriptFileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("teleprompter_script.txt")
    }

    private static func loadScript() -> String? {
        guard FileManager.default.fileExists(atPath: scriptFileURL.path) else { return nil }
        return try? String(contentsOf: scriptFileURL, encoding: .utf8)
    }

    static func saveScript(_ text: String) {
        try? text.write(to: scriptFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Init

    init() {
        let ud = UserDefaults.standard
        let shouldLoad = ud.bool(forKey: Keys.savePreferences)
        savePreferences = shouldLoad

        if shouldLoad {
            resolution             = VideoResolution(rawValue: ud.string(forKey: Keys.resolution) ?? "")             ?? .hd1080p
            frameRate              = FrameRate(rawValue: ud.integer(forKey: Keys.frameRate))                          ?? .fps30
            bitrate                = VideoBitrate(rawValue: ud.string(forKey: Keys.bitrate) ?? "")                   ?? .balanced
            appleLog               = ud.bool(forKey: Keys.appleLog)
            isTimelapse            = ud.bool(forKey: Keys.isTimelapse)
            timelapseSpeed         = TimelapseSpeed(rawValue: ud.integer(forKey: Keys.timelapseSpeed))                ?? .tenX
            cameraAssignment       = CameraAssignment(rawValue: ud.string(forKey: Keys.cameraAssignment) ?? "")      ?? .widePortrait
            dualLensUseFrontCamera = false   // always start on rear camera
            isSingleLensMode       = ud.bool(forKey: Keys.isSingleLensMode)
            isFrontBackMode        = ud.bool(forKey: Keys.isFrontBackMode)
            showGrid               = ud.bool(forKey: Keys.showGrid)
            showLevel              = ud.bool(forKey: Keys.showLevel)
            showTeleprompter       = ud.bool(forKey: Keys.showTeleprompter)
            teleprompterSpeed      = TeleprompterSpeed(rawValue: ud.string(forKey: Keys.teleprompterSpeed) ?? "") ?? .medium
        } else {
            resolution             = .hd1080p
            frameRate              = .fps30
            bitrate                = .balanced
            appleLog               = false
            isTimelapse            = false
            timelapseSpeed         = .tenX
            cameraAssignment       = .widePortrait
            dualLensUseFrontCamera = false
            isSingleLensMode       = false
            isFrontBackMode        = false
            showGrid               = false
            showLevel              = false
            showTeleprompter       = false
            teleprompterSpeed      = .medium
        }

        // Teleprompter script is always loaded — it's content, not a preference.
        teleprompterText = RecordingSettings.loadScript() ?? ""
    }

    // MARK: - Save All (called when savePreferences is enabled)

    private func saveAllSettings() {
        let ud = UserDefaults.standard
        ud.set(resolution.rawValue,          forKey: Keys.resolution)
        ud.set(frameRate.rawValue,           forKey: Keys.frameRate)
        ud.set(bitrate.rawValue,             forKey: Keys.bitrate)
        ud.set(appleLog,                     forKey: Keys.appleLog)
        ud.set(isTimelapse,                  forKey: Keys.isTimelapse)
        ud.set(timelapseSpeed.rawValue,      forKey: Keys.timelapseSpeed)
        ud.set(cameraAssignment.rawValue,    forKey: Keys.cameraAssignment)
        // dualLensUseFrontCamera intentionally not saved — resets to rear on every launch
        ud.set(isSingleLensMode,             forKey: Keys.isSingleLensMode)
        ud.set(isFrontBackMode,              forKey: Keys.isFrontBackMode)
        ud.set(showGrid,                     forKey: Keys.showGrid)
        ud.set(showLevel,                    forKey: Keys.showLevel)
        ud.set(showTeleprompter,             forKey: Keys.showTeleprompter)
        ud.set(teleprompterSpeed.rawValue,   forKey: Keys.teleprompterSpeed)
    }

    // MARK: - Encoder Settings

    private var encoderBitsPerSecond: Int {
        let baseMbps: Double = 20.0
        let resMult: Double  = resolution == .uhd4K ? 4.0 : 1.0
        let fpsMult: Double  = Double(frameRate.rawValue) / 30.0
        return Int(baseMbps * resMult * fpsMult * bitrate.multiplier * 1_000_000)
    }

    var portraitVideoSettings: [String: Any] {
        let dims = resolution.portraitDimensions
        return [
            AVVideoCodecKey: fileFormat.videoCodec,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: encoderBitsPerSecond] as [String: Any]
        ]
    }

    var landscapeVideoSettings: [String: Any] {
        let dims = resolution.landscapeDimensions
        return [
            AVVideoCodecKey: fileFormat.videoCodec,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: encoderBitsPerSecond] as [String: Any]
        ]
    }

    var audioSettings: [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]
    }

    func portraitFileURL() -> URL {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let uid = UUID().uuidString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("evershot_portrait_\(ms)_\(uid).\(fileFormat.fileExtension)")
    }

    func landscapeFileURL() -> URL {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let uid = UUID().uuidString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("evershot_landscape_\(ms)_\(uid).\(fileFormat.fileExtension)")
    }

    /// Front-camera portrait file URL for Front/Back mode.
    func frontFileURL() -> URL {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let uid = UUID().uuidString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("evershot_front_\(ms)_\(uid).\(fileFormat.fileExtension)")
    }

    /// Rear-camera portrait file URL for Front/Back mode.
    func rearFileURL() -> URL {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let uid = UUID().uuidString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("evershot_rear_\(ms)_\(uid).\(fileFormat.fileExtension)")
    }
}
