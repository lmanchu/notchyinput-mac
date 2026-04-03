import SwiftUI

/// SwiftUI content rendered inside the notch pill.
struct NotchPillContent: View {
    var isHovering: Bool = false

    var body: some View {
        ZStack {
            switch RecordingState.current {
            case .idle:
                if isHovering {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        Text("Voice Input")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .transition(.opacity)
                }

            case .loading(let message, let progress):
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.cyan)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.cyan)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.easeOut(duration: 0.3), value: progress)
                        }
                    }
                    .frame(height: 4)

                    Text(message)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .transition(.scale.combined(with: .opacity))

            case .recording:
                HStack(spacing: 8) {
                    // Pulsing mic icon
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.red)
                        .scaleEffect(1.0 + CGFloat(RecordingState.level) * 0.3)
                        .animation(.easeInOut(duration: 0.1), value: RecordingState.level)

                    Spacer()

                    // Audio level bars
                    AudioLevelView()
                        .frame(width: 30, height: 14)
                }
                .transition(.scale.combined(with: .opacity))

            case .processing:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.orange)
                    Spacer()
                    SpinnerView()
                        .frame(width: 14, height: 14)
                }
                .transition(.scale.combined(with: .opacity))

            case .done:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.green)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: RecordingState.current)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .offset(y: -2)
    }
}

// MARK: - Audio level visualization

struct AudioLevelView: View {
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let threshold = Float(i) / Float(barCount)
                let active = RecordingState.level > threshold
                RoundedRectangle(cornerRadius: 1)
                    .fill(active ? Color.red : Color.white.opacity(0.2))
                    .frame(width: 3)
                    .scaleEffect(y: active ? 0.5 + CGFloat(RecordingState.level) * 0.5 : 0.3, anchor: .bottom)
                    .animation(.easeOut(duration: 0.08), value: RecordingState.level)
            }
        }
    }
}

// MARK: - Spinner

struct SpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}
