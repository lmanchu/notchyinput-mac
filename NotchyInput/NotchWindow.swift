import AppKit
import SwiftUI
import Combine

/// Recording state for the notch display
enum RecordingDisplayState: Equatable {
    case idle
    case loading(message: String, progress: Float)
    case recording
    case processing
    case done(text: String)
}

/// Notification posted when recording state changes
extension Notification.Name {
    static let recordingStateChanged = Notification.Name("recordingStateChanged")
}

/// File-based animation diagnostic log (~/notchyinput-anim.log). Disabled in release.
fileprivate func animLog(_ msg: String) {
    #if DEBUG
    let line = "\(Date()) [anim] \(msg)\n"
    let path = NSHomeDirectory() + "/notchyinput-anim.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
    #endif
}

/// Legacy compatibility shim — proxies to RecordingViewModel.shared so AppDelegate keeps working.
/// All real state lives in RecordingViewModel now; SwiftUI observes that.
final class RecordingState {
    static var current: RecordingDisplayState {
        get { RecordingViewModel.shared.state }
        set {
            DispatchQueue.main.async {RecordingViewModel.shared.setState(newValue) }
        }
    }
    static var level: Float {
        get { RecordingViewModel.shared.level }
        set { DispatchQueue.main.async {RecordingViewModel.shared.level = newValue } }
    }
    static var waveform: [Float] {
        get { RecordingViewModel.shared.waveform }
        set { DispatchQueue.main.async {RecordingViewModel.shared.waveform = newValue } }
    }
    static var recordingStart: Date? {
        get { RecordingViewModel.shared.recordingStart }
        set { DispatchQueue.main.async {RecordingViewModel.shared.recordingStart = newValue } }
    }

    static func pushLevel(_ l: Float) {
        DispatchQueue.main.async {RecordingViewModel.shared.pushLevel(l) }
    }
}

/// An invisible window that sits behind the notch area.
/// Hover triggers a callback; expands when recording.
class NotchWindow: NSPanel {
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: Any?
    private var statusObserver: Any?
    var onClick: (() -> Void)?

    private var notchWidth: CGFloat = 180
    private var notchHeight: CGFloat = 37
    private var isExpanded = false
    private var collapseDebounceTimer: Timer?
    private var isHovered = false
    private let pillView = NotchPillView()
    private var pillContentHost: NSHostingView<NotchPillContent>?
    private let viewModel = RecordingViewModel.shared
    private var stateCancellable: Any?

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        alphaValue = 1

        if let cv = contentView {
            pillView.frame = cv.bounds
            pillView.autoresizingMask = [.width, .height]
            pillView.alphaValue = 1
            cv.addSubview(pillView)
            cv.wantsLayer = true
            cv.layer?.masksToBounds = false

            let hostView = NSHostingView(rootView: NotchPillContent(vm: viewModel))
            hostView.frame = cv.bounds
            hostView.autoresizingMask = [.width, .height]
            hostView.alphaValue = 1
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = .clear
            cv.addSubview(hostView)
            pillContentHost = hostView
        }

        detectNotchSize()
        positionAtNotch()
        orderFrontRegardless()
        setupTracking()
        observeScreenChanges()
        observeStatusChanges()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    deinit {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        if let o = statusObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Expand / Collapse

    private func observeStatusChanges() {
        animLog("observeStatusChanges: subscribing to viewModel.$state")
        stateCancellable = viewModel.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                animLog("vm.state changed to \(newState); self=\(self == nil ? "nil" : "alive")")
                self?.updateExpansionState()
            }
        animLog("observeStatusChanges: subscription=\(stateCancellable == nil ? "nil" : "ok")")
    }

    private func updateExpansionState() {
        let shouldExpand = viewModel.state != .idle
        animLog("updateExpansionState: shouldExpand=\(shouldExpand) isExpanded=\(isExpanded) current=\(viewModel.state)")

        if shouldExpand && !isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
            expandWithBounce()
        } else if !shouldExpand && isExpanded {
            guard collapseDebounceTimer == nil else { return }
            collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.collapseDebounceTimer = nil
                if self.viewModel.state == .idle && self.isExpanded {
                    self.collapse()
                }
            }
        } else if shouldExpand && isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
        }
        // NOTE: no more pillContentHost.rootView reassignment — SwiftUI diffs via @ObservedObject
    }

    private func expandWithBounce() {
        animLog("expandWithBounce called")
        isExpanded = true
        guard let screen = NSScreen.builtIn else { animLog("expandWithBounce: no builtin screen, bail"); return }
        let screenFrame = screen.frame

        let targetWidth: CGFloat = notchWidth + 80
        let targetFrame = NSRect(
            x: screenFrame.midX - targetWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: targetWidth,
            height: notchHeight
        )

        pillView.alphaValue = 1
        pillContentHost?.alphaValue = 1

        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.6

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let bounce = Self.bounceEase(t)

            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * bounce
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * bounce

            DispatchQueue.main.async {
                self.setFrame(
                    NSRect(x: currentX, y: targetFrame.origin.y, width: currentWidth, height: targetFrame.height),
                    display: true
                )
            }
            return t < 1.0
        }
        displayLink.start()
    }

    private func collapse() {
        isExpanded = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.pillContentHost?.animator().alphaValue = 0
        }

        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame

        let targetFrame = NSRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )

        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.3

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let ease = 1.0 - pow(1.0 - t, 3.0)

            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * ease
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * ease

            DispatchQueue.main.async {
                self.setFrame(
                    NSRect(x: currentX, y: targetFrame.origin.y, width: currentWidth, height: targetFrame.height),
                    display: true
                )
                if t >= 1.0 {
                    self.pillContentHost?.alphaValue = 1
                }
            }
            return t < 1.0
        }
        displayLink.start()
    }

    private static func bounceEase(_ t: Double) -> Double {
        let omega = 12.0
        let zeta = 0.4
        return 1.0 - exp(-zeta * omega * t) * cos(sqrt(1.0 - zeta * zeta) * omega * t)
    }

    // MARK: - Notch size detection

    private func detectNotchSize() {
        guard let screen = NSScreen.builtIn else { return }
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            notchHeight = screen.frame.maxY - min(left.minY, right.minY)
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchWidth = 180
            notchHeight = max(menuBarHeight, 25)
        }
    }

    private func positionAtNotch() {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        setFrame(NSRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        ), display: true)
    }

    // MARK: - Mouse tracking

    private func setupTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.checkMouse()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.checkMouse()
            return event
        }
    }

    private func checkMouse() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let effectiveWidth = isExpanded ? notchWidth + 80 : notchWidth
        let notchRect = NSRect(
            x: screenFrame.midX - effectiveWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: effectiveWidth,
            height: notchHeight + 1
        )

        if notchRect.contains(mouseLocation) {
            if !isHovered {
                isHovered = true
                DispatchQueue.main.async { [weak self] in self?.viewModel.isHovering = true }
            }
        } else if isHovered {
            isHovered = false
            DispatchQueue.main.async { [weak self] in self?.viewModel.isHovering = false }
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.detectNotchSize()
            self?.positionAtNotch()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - NSScreen helper

extension NSScreen {
    static var builtIn: NSScreen? {
        screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) != 0
        } ?? main
    }
}

// MARK: - Pill background view

class NotchPillView: NSView {
    var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    private let shapeLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = .clear
        shapeLayer.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateShape()
    }

    private func updateShape() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        shapeLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let path = CGMutablePath()
        let cr: CGFloat = 9.5
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: cr))
        path.addQuadCurve(to: CGPoint(x: w - cr, y: 0), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: cr, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: cr), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()

        shapeLayer.path = path
    }
}

// MARK: - CVDisplayLink wrapper

class CVDisplayLinkWrapper {
    private var displayLink: CVDisplayLink?
    private let callback: () -> Bool
    private var stopped = false

    init(callback: @escaping () -> Bool) {
        self.callback = callback
    }

    private static var fireCount: Int = 0

    func start() {
        animLog("CVDisplayLinkWrapper.start()")
        let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        animLog("CVDisplayLinkCreateWithActiveCGDisplays = \(createResult), link=\(displayLink == nil ? "nil" : "ok")")
        guard let displayLink else { animLog("displayLink is nil — bailing"); return }

        let opaqueWrapper = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let wrapper = Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            CVDisplayLinkWrapper.fireCount += 1
            if CVDisplayLinkWrapper.fireCount <= 3 || CVDisplayLinkWrapper.fireCount % 30 == 0 {
                animLog("CVDisplayLink fire #\(CVDisplayLinkWrapper.fireCount) stopped=\(wrapper.stopped)")
            }
            guard !wrapper.stopped else { return kCVReturnSuccess }
            let keepRunning = wrapper.callback()
            if !keepRunning {
                wrapper.stopped = true
                if let link = wrapper.displayLink { CVDisplayLinkStop(link) }
                DispatchQueue.main.async {
                    wrapper.displayLink = nil
                    Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).release()
                }
            }
            return kCVReturnSuccess
        }, opaqueWrapper.toOpaque())

        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        stopped = true
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }
}
