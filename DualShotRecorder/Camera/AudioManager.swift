import AVFoundation

/// Manages shared audio input for recording. Audio buffers are distributed
/// to all active asset writers.
final class AudioManager: NSObject {

    private let audioQueue = DispatchQueue(label: "com.evershot.audio", qos: .userInitiated)

    /// Callback invoked for each audio sample buffer. Both recorders register here.
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    /// The audio data output for the capture session
    private(set) var audioOutput: AVCaptureAudioDataOutput?

    /// The audio device input
    private(set) var audioInput: AVCaptureDeviceInput?

    // MARK: - Setup

    /// Creates and configures the audio input and output.
    /// Returns the input and output to be added to the session manually.
    func configure() -> (input: AVCaptureDeviceInput, output: AVCaptureAudioDataOutput)? {
        guard let mic = DeviceCapabilities.microphone else {
            print("AudioManager: No microphone available")
            return nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: mic)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: audioQueue)

            self.audioInput = input
            self.audioOutput = output
            return (input, output)
        } catch {
            print("AudioManager: Failed to create audio input: \(error)")
            return nil
        }
    }

    /// Resets the audio manager
    func reset() {
        onAudioBuffer = nil
        audioInput = nil
        audioOutput = nil
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onAudioBuffer?(sampleBuffer)
    }
}
