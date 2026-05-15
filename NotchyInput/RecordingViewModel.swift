import SwiftUI
import Combine

/// Observable bridge between AppKit-driven state and SwiftUI views.
/// Replaces the global static `RecordingState` + NotificationCenter pattern
/// that was forcing NSHostingView.rootView reassignment, which remounted the
/// SwiftUI tree and killed all transitions/withAnimation.
final class RecordingViewModel: ObservableObject {
    @Published var state: RecordingDisplayState = .idle
    @Published var level: Float = 0
    @Published var waveform: [Float] = Array(repeating: 0, count: 30)
    @Published var isHovering: Bool = false
    @Published var recordingStart: Date? = nil

    static let shared = RecordingViewModel()

    func setState(_ next: RecordingDisplayState) {
        if state != next { state = next }
    }

    func pushLevel(_ l: Float) {
        level = l
        waveform.append(l)
        if waveform.count > 30 { waveform.removeFirst() }
    }

    func resetWaveform() {
        waveform = Array(repeating: 0, count: 30)
    }
}
