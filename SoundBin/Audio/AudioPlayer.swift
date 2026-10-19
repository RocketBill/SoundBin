import AVFoundation
import Observation

/// Plays one file at a time through AVAudioEngine, so playback starts the instant a tile is clicked.
@Observable
final class AudioPlayer {
    private(set) var currentFile: AudioFile?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var lastError: String?

    var isLooping = UserDefaults.standard.bool(forKey: AudioPlayer.loopingKey) {
        didSet {
            UserDefaults.standard.set(isLooping, forKey: Self.loopingKey)
            if isLooping { playsNext = false }
        }
    }

    /// When a sound ends, carry on with the one after it. Off by default; exclusive with looping.
    var playsNext = UserDefaults.standard.bool(forKey: AudioPlayer.playsNextKey) {
        didSet {
            UserDefaults.standard.set(playsNext, forKey: Self.playsNextKey)
            if playsNext { isLooping = false }
        }
    }

    /// Supplies the sound after a given one, in the order the browser shows them.
    @ObservationIgnored var nextFile: ((AudioFile) -> AudioFile?)?

    var volume: Double = UserDefaults.standard.object(forKey: AudioPlayer.volumeKey) as? Double ?? 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = Float(volume)
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }

    var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    /// Frame the current segment was scheduled from; the node's own clock restarts at zero for each segment.
    @ObservationIgnored private var segmentStartFrame: AVAudioFramePosition = 0
    /// Chunks of the current segment queued on the node that haven't finished playing yet.
    @ObservationIgnored private var chunksInFlight = 0
    @ObservationIgnored private var reachedEndOfFile = false
    /// Bumped whenever playback is interrupted, so completion callbacks from old segments are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    private static let volumeKey = "playerVolume"
    private static let loopingKey = "playerLooping"
    private static let playsNextKey = "playerPlaysNext"
    /// Playback decodes the file in chunks of this length, keeping a few queued ahead of the playhead.
    private static let chunkDuration: TimeInterval = 0.5
    private static let chunksAhead = 4

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Float(volume)
        engine.prepare()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    // MARK: Transport

    /// Starts `file` from the beginning, or from `time` if given.
    func play(_ file: AudioFile, from time: TimeInterval = 0) {
        let opened: AVAudioFile
        do {
            opened = try AVAudioFile(forReading: file.url)
        } catch {
            stop()
            lastError = "Couldn’t play “\(file.displayName)”."
            return
        }
        lastError = nil
        interruptSegment()

        let format = opened.processingFormat
        if connectedFormat != format {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }

        audioFile = opened
        currentFile = file
        duration = Double(opened.length) / format.sampleRate
        startPlayback(at: time)
    }

    /// Click behaviour for tiles: clicking the sound that's playing stops it, anything else plays.
    func toggle(_ file: AudioFile) {
        if isPlaying, currentFile?.id == file.id {
            stop()
        } else {
            play(file)
        }
    }

    /// Transport-bar play/pause: resumes from the paused position rather than restarting.
    func togglePlayPause() {
        if isPlaying {
            pause()
            return
        }
        guard let currentFile else { return }
        let resumeAt = currentTime < duration ? currentTime : 0
        if audioFile == nil {
            play(currentFile, from: resumeAt)
        } else {
            startPlayback(at: resumeAt)
        }
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = livePosition()
        interruptSegment()
        isPlaying = false
        stopTicker()
    }

    /// Stops and rewinds. The file stays loaded so the transport can replay it.
    func stop() {
        interruptSegment()
        isPlaying = false
        currentTime = 0
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let target = min(max(0, time), duration)
        if isPlaying {
            interruptSegment()
            startPlayback(at: target)
        } else {
            currentTime = target
        }
    }

    // MARK: Engine

    private func startPlayback(at time: TimeInterval) {
        guard let audioFile else { return }
        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = min(AVAudioFramePosition(time * sampleRate), max(0, audioFile.length - 1))
        guard audioFile.length - startFrame > 0 else { return }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            lastError = "The audio output couldn’t be started."
            return
        }

        generation += 1
        segmentStartFrame = startFrame
        audioFile.framePosition = startFrame
        chunksInFlight = 0
        reachedEndOfFile = false
        for _ in 0..<Self.chunksAhead {
            scheduleNextChunk()
        }
        guard chunksInFlight > 0 else {
            stop()
            if startFrame == 0, let currentFile {
                lastError = "Couldn’t play “\(currentFile.displayName)”."
            }
            return
        }
        playerNode.play()
        currentTime = Double(startFrame) / sampleRate
        isPlaying = true
        startTicker()
    }

    private func interruptSegment() {
        generation += 1
        playerNode.stop()
    }

    /// Decodes the next chunk and queues it on the node. Scheduling the file on the node directly
    /// (`scheduleSegment`/`scheduleFile`) plays nothing at all for files whose header overstates their
    /// length, which is common with Ogg Vorbis; reading it ourselves just stops at the real end.
    private func scheduleNextChunk() {
        guard !reachedEndOfFile, let audioFile else { return }
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * Self.chunkDuration)
        ) else { return }
        do {
            try audioFile.read(into: buffer)
        } catch {
            buffer.frameLength = 0
        }
        guard buffer.frameLength > 0 else {
            reachedEndOfFile = true
            return
        }

        let scheduledGeneration = generation
        chunksInFlight += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.chunkFinished(scheduledGeneration) }
        }
    }

    private func chunkFinished(_ finishedGeneration: Int) {
        guard finishedGeneration == generation, isPlaying else { return }
        chunksInFlight -= 1
        scheduleNextChunk()
        guard chunksInFlight == 0 else { return }
        if isLooping {
            // Stopping the node restarts its clock, which `livePosition()` measures from.
            interruptSegment()
            startPlayback(at: 0)
        } else if playsNext, let currentFile, let next = nextFile?(currentFile) {
            play(next)
        } else {
            stop()
        }
    }

    private func livePosition() -> TimeInterval {
        guard let audioFile,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return currentTime }
        let frame = segmentStartFrame + playerTime.sampleTime
        return min(duration, max(0, Double(frame) / audioFile.processingFormat.sampleRate))
    }

    private func handleConfigurationChange() {
        // The output device changed (headphones unplugged, interface switched). The engine stops itself;
        // pick up where we were on the new device.
        connectedFormat = nil
        guard let currentFile else { return }
        let wasPlaying = isPlaying
        let position = isPlaying ? livePosition() : currentTime
        if wasPlaying {
            play(currentFile, from: position)
        } else {
            audioFile = nil
        }
    }

    // MARK: Ticker

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying else { return }
        currentTime = livePosition()
    }
}
