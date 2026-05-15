import Foundation

/// State machine for the ASR sidecar lifecycle.
///
/// NOT WIRED. Drop-in replacement target for ASRBridge's implicit
/// {isReady, isRestarting, healthTimer} bag. Adopt incrementally:
/// 1. Make ASRBridge hold `private var state: ASRState = .dead`
/// 2. Replace `isReady` reads with `state == .ready`
/// 3. Replace `isRestarting` flag with `state == .booting` after restart
/// 4. Gate transcribe on `state.canTranscribe`
/// 5. Move health-ping into `.ready` only; restart goes through `.dying → .dead → .booting`
///
/// Invariant: only the actor mutates `state`. Reads from other queues
/// must hop onto the actor.
enum ASRState: Equatable {
    case dead                          // no process, no resources
    case booting                       // process started, awaiting "ready" line
    case ready                         // model loaded, can accept transcribe
    case busy                          // mid-transcription
    case pinging                       // health check in flight
    case dying(reason: String)         // terminate sent, awaiting cleanup

    var canTranscribe: Bool { self == .ready }
    var canPing: Bool { self == .ready }
    var needsRestart: Bool {
        if case .dying = self { return true }
        return self == .dead
    }
}

/// Owns the ASR state. All mutations serialized through the actor.
/// Replaces the {isRestarting flag + restartQueue + main-queue Timer}
/// implicit coordination in ASRBridge.
actor ASRStateMachine {
    private(set) var state: ASRState = .dead
    private var transitionListeners: [(ASRState, ASRState) -> Void] = []

    func transition(to next: ASRState) {
        let prev = state
        guard isLegal(from: prev, to: next) else {
            NSLog("[asr-state] ILLEGAL transition %@ → %@", "\(prev)", "\(next)")
            return
        }
        state = next
        NSLog("[asr-state] %@ → %@", "\(prev)", "\(next)")
        for listener in transitionListeners {
            listener(prev, next)
        }
    }

    func onTransition(_ block: @escaping (ASRState, ASRState) -> Void) {
        transitionListeners.append(block)
    }

    /// Legal transitions only. Anything else gets logged + dropped.
    /// Drawn as a graph:
    ///   dead → booting → ready ⇄ busy
    ///                    ready ⇄ pinging
    ///                    (any) → dying → dead
    private func isLegal(from: ASRState, to: ASRState) -> Bool {
        if case .dying = to { return true }            // anything can die
        if from == .dead && to == .booting { return true }
        if from == .booting && to == .ready { return true }
        if from == .ready && to == .busy { return true }
        if from == .busy && to == .ready { return true }
        if from == .ready && to == .pinging { return true }
        if from == .pinging && to == .ready { return true }
        if case .dying = from, to == .dead { return true }
        return false
    }
}
