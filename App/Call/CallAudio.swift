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
    /// Fires on the main actor whenever queued playback finishes (the queue became empty).
    var onPlaybackIdle: (() -> Void)?

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

    /// Samples scheduled and actually played back per item, for `conversation.item.truncate`.
    /// Counted from buffer completions: the player's own clock keeps running while idle.
    private var scheduled: [(item: PlaybackItem, samples: Int, played: Int)] = []
    private var buffersInFlight = 0
    /// Bumped by `clear()` so completions of dropped buffers are ignored.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    var isPlaying: Bool { hasQueuedAudio && !isPaused }
    var hasQueuedAudio: Bool { buffersInFlight > 0 }

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
        generation += 1
        scheduled.removeAll()
        buffersInFlight = 0
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
            scheduled.append((item, count, 0))
        }
        buffersInFlight += 1
        let generation = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(count, for: item, generation: generation) }
        }
        if !isPaused, !player.isPlaying { player.play() }
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused { player.pause() } else { player.play() }
    }

    /// Drops queued audio and reports how much of each item was actually heard.
    /// Granularity is one network chunk (whatever the provider sent per delta).
    func clear() -> [(item: PlaybackItem, playedMs: Int)] {
        let result = scheduled.map { ($0.item, Int(Double($0.played) / Self.sampleRate * 1000)) }
        generation += 1
        player.stop()
        scheduled.removeAll()
        buffersInFlight = 0
        if !isPaused { player.play() }
        return result
    }

    private func played(_ count: Int, for item: PlaybackItem, generation: Int) {
        guard generation == self.generation else { return }
        if let index = scheduled.firstIndex(where: { $0.item == item }) {
            scheduled[index].played += count
        }
        buffersInFlight -= 1
        if buffersInFlight == 0 {
            scheduled.removeAll()
            onPlaybackIdle?()
        }
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
