import AVFoundation
import Accelerate

/// Records audio from the default input device using AVAudioEngine.
/// Produces 16kHz mono Int16 WAV data, matching Qwen3-ASR's expected format.
/// Maintains a 0.35s pre-buffer so the start of speech isn't clipped.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000
    private let preBufferSeconds: Double = 0.35

    private var preBuffer: [[Int16]] = []
    private var preBufferMaxChunks: Int = 0
    private var frames: [[Int16]] = []
    private var isRecording = false
    private let lock = NSLock()

    /// RMS level callback (0.0–1.0), called on audio thread
    var levelCallback: ((Float) -> Void)?

    init() {
        preBufferMaxChunks = Int(preBufferSeconds / 0.05) + 2
        setupEngine()
    }

    private func setupEngine() {
        let inputNode = engine.inputNode
        // Request 16kHz mono format
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

        // Install tap — the hardware format may differ, but we convert in the tap
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * 0.05)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        // Prepare converter from hardware format to 16kHz Int16
        _converter = AVAudioConverter(from: hardwareFormat, to: desiredFormat)
    }

    private var _converter: AVAudioConverter?

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = _converter else { return }

        let outputFrameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate
        )
        guard outputFrameCapacity > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("[recorder] convert error: \(error)")
            return
        }

        guard outputBuffer.frameLength > 0 else { return }

        // Extract Int16 samples
        let int16Ptr = outputBuffer.int16ChannelData![0]
        let chunk = Array(UnsafeBufferPointer(start: int16Ptr, count: Int(outputBuffer.frameLength)))

        lock.lock()
        if isRecording {
            frames.append(chunk)
        } else {
            preBuffer.append(chunk)
            if preBuffer.count > preBufferMaxChunks {
                preBuffer.removeFirst()
            }
        }
        lock.unlock()

        // Report level
        if isRecording, let cb = levelCallback {
            let floats = chunk.map { Float($0) / 32768.0 }
            var rms: Float = 0
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(floats.count))
            cb(min(rms * 10, 1.0))
        }
    }

    func startEngine() {
        do {
            try engine.start()
            print("[recorder] Audio engine started")
        } catch {
            print("[recorder] Failed to start engine: \(error)")
        }
    }

    func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    func start() {
        lock.lock()
        guard !isRecording else { lock.unlock(); return }
        frames = Array(preBuffer) // capture pre-buffer
        isRecording = true
        lock.unlock()
    }

    func stop() -> Data {
        lock.lock()
        isRecording = false
        let captured = frames
        frames = []
        preBuffer = []
        lock.unlock()

        return toWAV(captured)
    }

    private func toWAV(_ chunks: [[Int16]]) -> Data {
        let allSamples = chunks.flatMap { $0 }
        guard !allSamples.isEmpty else { return Data() }

        var data = Data()
        let dataSize = UInt32(allSamples.count * 2) // Int16 = 2 bytes
        let fileSize = 36 + dataSize

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) }) // sample rate
        data.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) }) // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        allSamples.withUnsafeBufferPointer { ptr in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.baseAddress!).assumingMemoryBound(to: UInt8.self), count: Int(dataSize)))
        }

        return data
    }
}
