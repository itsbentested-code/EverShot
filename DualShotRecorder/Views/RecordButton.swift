import SwiftUI

/// The main record button — a large red circle that matches the standard camera app convention.
/// Animates between idle and recording states.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 80, height: 80)

                // Inner shape — circle when idle, rounded square (stop) when recording
                if isRecording {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 68, height: 68)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
    }
}

// MARK: - Pause Button

/// Pause / resume button shown alongside the stop button while recording.
struct PauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 64, height: 64)

                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPaused)
        .accessibilityLabel(isPaused ? "Resume Recording" : "Pause Recording")
    }
}

// MARK: - Recording Controls

/// Bottom control bar: pause + stop while recording, single record button otherwise.
struct RecordingControls: View {
    let isRecording: Bool
    let isPaused: Bool
    let onRecord: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        if isRecording {
            HStack(spacing: 36) {
                PauseButton(isPaused: isPaused, action: onPause)
                RecordButton(isRecording: true, action: onStop)
            }
        } else {
            RecordButton(isRecording: false, action: onRecord)
        }
    }
}

// MARK: - Recording Timer Display

struct RecordingTimerView: View {
    let duration: TimeInterval
    let isRecording: Bool
    let isPaused: Bool

    @State private var dotVisible = true

    var body: some View {
        HStack(spacing: 8) {
            // Dot pulses red while recording, solid yellow while paused
            Circle()
                .fill(isPaused ? Color.yellow : Color.red)
                .frame(width: 10, height: 10)
                .opacity(dotVisible ? 1.0 : 0.3)
                .animation(
                    (isRecording && !isPaused) ?
                        .easeInOut(duration: 0.6).repeatForever(autoreverses: true) :
                        .default,
                    value: dotVisible
                )
                .onAppear {
                    if isRecording && !isPaused { dotVisible.toggle() }
                }
                .onChange(of: isRecording) { recording in
                    dotVisible = recording ? false : true
                }
                .onChange(of: isPaused) { paused in
                    dotVisible = paused ? true : false
                }

            // Timer text
            Text(formattedDuration)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(isPaused ? .yellow : .white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.5))
        )
    }

    private var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
