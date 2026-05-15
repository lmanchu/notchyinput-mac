import SwiftUI

/// SwiftUI content rendered inside the notch pill — rich animations for each state.
/// Observes RecordingViewModel so SwiftUI can diff in-place (no more NSHostingView root reassign).
struct NotchPillContent: View {
    @ObservedObject var vm: RecordingViewModel

    var body: some View {
        ZStack {
            // Glow overlay (behind content, visible during recording)
            if case .recording = vm.state {
                RecordingGlowView()
            }

            // Main content
            switch vm.state {
            case .idle:
                IdleView(isHovering: vm.isHovering)

            case .loading(let message, let progress):
                LoadingView(message: message, progress: progress)

            case .recording:
                RecordingView(vm: vm)

            case .processing:
                ProcessingView()

            case .done(let text):
                DoneView(text: text)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: vm.state)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .offset(y: -2)
    }
}

// MARK: - Idle: breathing mic icon

struct IdleView: View {
    var isHovering: Bool
    @State private var breathing = false

    var body: some View {
        if isHovering {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .scaleEffect(breathing ? 1.1 : 0.95)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: breathing)
                Text("Voice Input")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .transition(.opacity)
            .onAppear { breathing = true }
        } else {
            // Subtle breathing dot to show app is ready
            Circle()
                .fill(Color.white.opacity(breathing ? 0.3 : 0.1))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: breathing)
                .onAppear { breathing = true }
        }
    }
}

// MARK: - Loading: progress bar + shimmer

struct LoadingView: View {
    let message: String
    let progress: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.cyan)

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
    }
}

// MARK: - Recording: waveform + timer + ripples

struct RecordingView: View {
    @ObservedObject var vm: RecordingViewModel
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 6) {
            // Mic icon with ripple rings
            ZStack {
                RippleRingsView()
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.red)
                    .scaleEffect(1.0 + CGFloat(vm.level) * 0.25)
                    .animation(.easeOut(duration: 0.08), value: vm.level)
            }
            .frame(width: 24, height: 24)

            // Waveform
            WaveformView(samples: vm.waveform)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Timer
            Text(formatTime(elapsed))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.red.opacity(0.9))
        }
        .transition(.scale.combined(with: .opacity))
        .onAppear {
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if let start = vm.recordingStart {
                    elapsed = Date().timeIntervalSince(start)
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let secs = Int(t) % 60
        let mins = Int(t) / 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Waveform visualization

struct WaveformView: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1.5
            let maxBars = Int(geo.size.width / (barWidth + gap))
            let displaySamples = Array(samples.suffix(maxBars))

            HStack(spacing: gap) {
                ForEach(Array(displaySamples.enumerated()), id: \.offset) { _, level in
                    let h = max(CGFloat(level) * geo.size.height, 2)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(Color.red.opacity(0.6 + Double(level) * 0.4))
                        .frame(width: barWidth, height: h)
                        .animation(.easeOut(duration: 0.06), value: level)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Ripple rings (expanding circles from mic)

struct RippleRingsView: View {
    @State private var animate = false
    private let ringCount = 2

    var body: some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { i in
                Circle()
                    .stroke(Color.red.opacity(animate ? 0 : 0.4), lineWidth: 1.5)
                    .scaleEffect(animate ? 2.5 : 0.8)
                    .animation(
                        .easeOut(duration: 1.5)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.6),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - Recording glow (red glow behind pill)

struct RecordingGlowView: View {
    @State private var glowing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.red.opacity(glowing ? 0.15 : 0.05))
            .blur(radius: 8)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: glowing)
            .onAppear { glowing = true }
    }
}

// MARK: - Processing: shimmer + typewriter

struct ProcessingView: View {
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.orange)

            Spacer()

            // Shimmer bar
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))

                    // Shimmer gradient sweep
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.3), .clear],
                                startPoint: UnitPoint(x: shimmerOffset, y: 0.5),
                                endPoint: UnitPoint(x: shimmerOffset + 0.4, y: 0.5)
                            )
                        )
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: shimmerOffset)
                }
            }
            .frame(width: 50, height: 6)

            TypewriterText(text: "Transcribing")
                .frame(width: 70, alignment: .leading)
        }
        .transition(.scale.combined(with: .opacity))
        .onAppear { shimmerOffset = 1.4 }
    }
}

struct TypewriterText: View {
    let text: String
    @State private var dots = 0
    @State private var timer: Timer?

    var body: some View {
        Text(text + String(repeating: ".", count: dots))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .onAppear {
                timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                    dots = (dots + 1) % 4
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}

// MARK: - Done: animated checkmark + text preview

struct DoneView: View {
    let text: String
    @State private var checkmarkProgress: CGFloat = 0
    @State private var showText = false
    @State private var flashOpacity: Double = 0.4

    var body: some View {
        HStack(spacing: 8) {
            AnimatedCheckmark(progress: checkmarkProgress)
                .frame(width: 16, height: 16)

            if flashOpacity > 0 {
                Color.green.opacity(flashOpacity)
                    .frame(width: 2, height: 14)
                    .cornerRadius(1)
            }

            if showText {
                Text(String(text.prefix(20)))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green.opacity(0.8))
                    .lineLimit(1)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .transition(.scale.combined(with: .opacity))
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                checkmarkProgress = 1.0
            }
            withAnimation(.easeOut(duration: 0.6)) {
                flashOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showText = true
                }
            }
        }
    }
}

struct AnimatedCheckmark: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                path.move(to: CGPoint(x: w * 0.15, y: h * 0.55))
                path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.8))
                path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.2))
            }
            .trim(from: 0, to: progress)
            .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}
