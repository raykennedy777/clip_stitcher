import AVFoundation

final class AudioStreamPlayer {
    static let sampleRate = 48_000
    static let channelCount = 2
    private static let bytesPerFrame = channelCount * MemoryLayout<Float>.size
    private static let chunkFrames = 4096
    private static let maxQueuedBuffers = 12

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channelCount))!

    private let queue = DispatchQueue(label: "io.github.raykennedy777.clipstitcher.audioplayer")
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0

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

    var elapsedSeconds: Double? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func start(url: URL, streamIndex: Int, seekSeconds: Double,
               filter: String? = nil, duration: Double? = nil) {
        startDecode(arguments: Self.arguments(
            filePath: url.path, streamIndex: streamIndex, seekSeconds: seekSeconds,
            filter: filter, duration: duration))
    }

    func startSilence(duration: Double) {
        startDecode(arguments: Self.silenceArguments(duration: duration))
    }

    private func startDecode(arguments: [String]) {
        stop()
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }

        let process = Process()
        process.executableURL = ffmpeg
        process.standardInput = FileHandle.nullDevice
        process.arguments = arguments
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

    func stop() {
        lock.lock()
        generation += 1
        let process = self.process
        self.process = nil
        lock.unlock()
        // ADR-0015
        if let process, process.isRunning { process.terminate() }
        node.stop()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    private func readLoop(handle: FileHandle, depth: QueueDepth, generation gen: Int) {
        defer { try? handle.close() }
        var pending = Data()
        var started = false
        while isCurrent(gen) {
            let chunk = handle.readData(ofLength: Self.chunkFrames * Self.bytesPerFrame)
            if chunk.isEmpty { break }
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

    static func arguments(filePath: String, streamIndex: Int, seekSeconds: Double,
                          filter: String? = nil, duration: Double? = nil) -> [String] {
        var args = ["-v", "error", "-ss", String(format: "%.6f", seekSeconds)]
        if let duration { args += ["-t", String(format: "%.6f", duration)] }
        args += ["-i", filePath, "-map", "0:a:\(streamIndex)", "-vn"]
        if let filter { args += ["-af", filter] }
        args += ["-f", "f32le", "-ac", "\(channelCount)", "-ar", "\(sampleRate)", "-"]
        return args
    }

    static func silenceArguments(duration: Double) -> [String] {
        [
            "-v", "error",
            "-t", String(format: "%.6f", duration),
            "-f", "lavfi", "-i", "anullsrc=r=\(sampleRate):cl=stereo",
            "-f", "f32le", "-ac", "\(channelCount)", "-ar", "\(sampleRate)",
            "-",
        ]
    }

    static func seekSeconds(sourceTime: Double, containerStartTime: Double) -> Double {
        max(0, sourceTime - containerStartTime)
    }
}
