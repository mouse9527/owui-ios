@preconcurrency import AVFoundation
import Foundation

/// Microphone capture and speaker playback for a realtime call, both PCM16 mono at 24 kHz on the wire.
///
/// Uses `.playAndRecord` + `.voiceChat`, so the system echo canceller removes our own playback from the
/// microphone. That is what lets the call run on the speaker without the web client's feedback noise.
/// All methods run on the main actor; the tap callback hops to it with already-converted frames.
@MainActor
final class CallAudio {
    static let sampleRate = 24_000.0
    /// 40 ms frames, matching the web AudioWorklet.
    static let frameSamples = 960

    struct PlaybackItem: Hashable {
        let responseID: String
        let itemID: String
        let contentIndex: Int
    }

    var onCapture: ((Data) -> Void)?
    var onInterruption: ((String) -> Void)?

    /// Paused playback keeps its queue; used while server VAD decides whether the user is really speaking.
    private(set) var isPaused = false
    var isCapturing = false
    var isMuted = false {
        didSet { if isMuted { pending.removeAll() } }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private var converter: AVAudioConverter?
    private var pending = Data()

    /// Samples scheduled / rendered per item, for `conversation.item.truncate`.
    private var scheduled: [(item: PlaybackItem, samples: Int)] = []
    private var queuedSamples = 0
    private var observers: [NSObjectProtocol] = []

    var isPlaying: Bool { queuedSamples > renderedSamples && !isPaused }
    var hasQueuedAudio: Bool { queuedSamples > renderedSamples }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: wireFormat)
        guard converter != nil else { throw CallAudioError.format }
        let wire = wireFormat
        let tapConverter = converter!
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let data = Self.convert(buffer, with: tapConverter, to: wire) else { return }
            Task { @MainActor in self?.captured(data) }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                if type == .began { self?.onInterruption?("通话被系统音频打断。") }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Route changes (headphones, Bluetooth) stop the engine; restart it in place.
            MainActor.assumeIsolated { try? self?.restartEngine() }
        })

        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        scheduled.removeAll()
        queuedSamples = 0
        pending.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Playback

    func enqueue(_ pcm: Data, for item: PlaybackItem) {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        if let last = scheduled.last, last.item == item {
            scheduled[scheduled.count - 1].samples += count
        } else {
            scheduled.append((item, count))
        }
        queuedSamples += count
        player.scheduleBuffer(buffer)
        if !isPaused, !player.isPlaying { player.play() }
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused { player.pause() } else { player.play() }
    }

    /// Drops queued audio and reports how much of each item was actually heard.
    func clear() -> [(item: PlaybackItem, playedMs: Int)] {
        var remaining = renderedSamples
        let latency = AVAudioSession.sharedInstance().outputLatency
        var result: [(PlaybackItem, Int)] = []
        for entry in scheduled {
            let played = min(entry.samples, max(0, remaining))
            remaining -= entry.samples
            let ms = max(0, Int(Double(played) / Self.sampleRate * 1000 - latency * 1000))
            result.append((entry.item, ms))
        }
        player.stop()
        scheduled.removeAll()
        queuedSamples = 0
        if !isPaused { player.play() }
        return result
    }

    private var renderedSamples: Int {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Int(Double(time.sampleTime) * Self.sampleRate / time.sampleRate)
    }

    // MARK: Capture

    private func captured(_ data: Data) {
        guard isCapturing, !isMuted else { return }
        pending.append(data)
        let frameBytes = Self.frameSamples * 2
        while pending.count >= frameBytes {
            onCapture?(pending.prefix(frameBytes))
            pending.removeFirst(frameBytes)
        }
    }

    private func restartEngine() throws {
        guard !engine.isRunning, !observers.isEmpty else { return }
        engine.prepare()
        try engine.start()
        if !isPaused { player.play() }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> Data? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}

enum CallAudioError: LocalizedError {
    case format

    var errorDescription: String? { "无法设置 24 kHz 音频格式。" }
}
