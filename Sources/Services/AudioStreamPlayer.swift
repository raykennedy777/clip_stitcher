import AVFoundation

/// Plays one audio stream of a media file by decoding it to PCM with an ffmpeg
/// subprocess (bundled CLI binaries — ADR-0002) and scheduling the samples on an
/// AVAudioPlayerNode. While running it is the **master clock** for playback
/// (issue #7): callers derive the video position from `elapsedSeconds` instead of
/// a timer, so pacing drift can't become lip-sync error. Built standalone so the
/// output preview (#8) can adopt it.
///
/// The clock starts at the first decoded sample and keeps advancing after the
/// stream ends — the node renders silence but its sample time still runs — so a
/// source shorter than the video, or a seek past its end, plays out as silence
/// without stalling the picture (ADR-0014 alignment semantics).
final class AudioStreamPlayer {
    /// Output PCM shape: every source is conformed to this by the ffmpeg command,
    /// so the engine graph never has to reconfigure per stream.
    static let sampleRate = 48_000
    static let channelCount = 2
    private static let bytesPerFrame = channelCount * MemoryLayout<Float>.size
    /// ~85 ms per scheduled buffer; with the queue cap this bounds lookahead to
    /// ~1 s of audio, and the blocked pipe holds ffmpeg back from decoding more.
    private static let chunkFrames = 4096
    private static let maxQueuedBuffers = 12

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channelCount))!

    /// Blocking pipe reads run here (never the main thread or the concurrency pool),
    /// mirroring FrameStreamDecoder's hygiene.
    private let queue = DispatchQueue(label: "com.conmotogroup.vidconform.audioplayer")
    private let lock = NSLock()
    private var process: Process?
    /// Bumped by `stop()`; a reader that wakes up under an older generation exits
    /// instead of scheduling stale audio onto a restarted node.
    private var generation = 0

    /// How many scheduled buffers the node hasn't consumed yet — the reader's
    /// backpressure gauge, one instance per stream session. Deliberately a plain
    /// lock-guarded counter and NOT a DispatchSemaphore: `node.stop()` destroys
    /// queued buffer commands *without invoking their completions* (measured:
    /// exactly one dropped per stop), and a semaphore captured in those blocks is
    /// then deallocated with outstanding waits — a libdispatch trap that crashed
    /// the app on a mid-play track switch. An undercounted Int is harmless; the
    /// session's counter dies with the session.
    private final class QueueDepth {
        private let lock = NSLock()
        private var queued = 0
        func increment() { lock.lock(); queued += 1; lock.unlock() }
        func decrement() { lock.lock(); queued -= 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return queued }
    }

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    deinit {
        stop()
        engine.stop()
    }

    /// Seconds of audio time since this start — the master clock. Counts from the
    /// first decoded sample (the node starts only once that sample is scheduled)
    /// and keeps running through end-of-stream silence. `nil` until the first
    /// samples arrive, or when the player isn't running.
    var elapsedSeconds: Double? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Starts streaming `streamIndex` (0-based among the file's audio streams) from
    /// `seekSeconds` into the file. Restarts cleanly if already playing — a seek or
    /// a monitor-track switch is just another `start`. Failure (missing ffmpeg,
    /// engine refusal, spawn error) leaves `elapsedSeconds` nil; the caller keeps
    /// its fallback clock.
    func start(url: URL, streamIndex: Int, seekSeconds: Double) {
        stop()
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = Self.arguments(
            filePath: url.path, streamIndex: streamIndex, seekSeconds: seekSeconds)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }

        lock.lock()
        self.process = process
        let gen = generation
        lock.unlock()

        let handle = pipe.fileHandleForReading
        let depth = QueueDepth()
        queue.async { [weak self] in
            self?.readLoop(handle: handle, depth: depth, generation: gen)
        }
    }

    /// Stops the stream and the clock: kills the ffmpeg process, halts the node,
    /// and invalidates the in-flight reader (its backpressure poll re-checks the
    /// generation, so it can't stay blocked). The engine stays warm so a restart
    /// is cheap.
    func stop() {
        lock.lock()
        generation += 1
        let process = self.process
        self.process = nil
        lock.unlock()
        // Terminating closes the pipe's write end, so a reader blocked in read()
        // sees EOF and exits; the reader closes its own handle (no cross-thread
        // close on a blocked FileHandle).
        if let process, process.isRunning { process.terminate() }
        node.stop()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    /// Drains the PCM pipe into scheduled buffers. Carves whole frames out of the
    /// byte stream (pipe reads return arbitrary lengths), starts the node — and the
    /// clock — when the first buffer is in, and lets EOF end the loop quietly: the
    /// node plays out what's queued, then silence. Backpressure is an interruptible
    /// poll of the queue depth — see `QueueDepth` for why it must not be a
    /// semaphore wait.
    private func readLoop(handle: FileHandle, depth: QueueDepth, generation gen: Int) {
        defer { try? handle.close() }
        var pending = Data()
        var started = false
        while isCurrent(gen) {
            let chunk = handle.readData(ofLength: Self.chunkFrames * Self.bytesPerFrame)
            if chunk.isEmpty { break } // EOF: source ended or process was stopped
            pending.append(chunk)
            let frames = min(pending.count / Self.bytesPerFrame, Self.chunkFrames)
            guard frames > 0 else { continue }
            guard let buffer = Self.makeBuffer(from: pending, frames: frames, format: format) else { break }
            pending.removeFirst(frames * Self.bytesPerFrame)
            while depth.count >= Self.maxQueuedBuffers {
                guard isCurrent(gen) else { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard isCurrent(gen) else { break }
            depth.increment()
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { _ in
                depth.decrement()
            }
            if !started {
                started = true
                node.play()
            }
        }
    }

    /// Deinterleaves `frames` frames of f32le stereo into a deinterleaved engine
    /// buffer (AVAudioEngine connections want the standard non-interleaved layout).
    private static func makeBuffer(from data: Data, frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for ch in 0..<channelCount {
                let dst = buffer.floatChannelData![ch]
                for f in 0..<frames { dst[f] = samples[f * channelCount + ch] }
            }
        }
        return buffer
    }

    // MARK: - Pure helpers (unit-tested)

    /// The PCM decode command: input-seek to `seekSeconds` (sample-exact —
    /// accurate_seek discards up to the target), decode one audio stream, conform
    /// to 48 kHz stereo float, stream to stdout.
    static func arguments(filePath: String, streamIndex: Int, seekSeconds: Double) -> [String] {
        [
            "-v", "error",
            "-ss", String(format: "%.6f", seekSeconds),
            "-i", filePath,
            "-map", "0:a:\(streamIndex)", "-vn",
            "-f", "f32le", "-ac", "\(channelCount)", "-ar", "\(sampleRate)",
            "-",
        ]
    }

    /// Converts a source presentation time to the input `-ss` value. ffmpeg input
    /// seeks are measured from the **container's** start_time, not absolute pts —
    /// the ADR-0013 trap, re-measured for this player: on a 0.24 s-start MPEG-PS,
    /// `-ss <absolute pts>` lands 0.24 s late (`-seek_timestamp 1` doesn't help).
    /// The same value also aligns an external audio file, whose timeline starts at
    /// the video file's start (ADR-0014) and whose own `-ss` is file-start-relative.
    static func seekSeconds(sourceTime: Double, containerStartTime: Double) -> Double {
        max(0, sourceTime - containerStartTime)
    }
}
