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
        didSet { UserDefaults.standard.set(isLooping, forKey: Self.loopingKey) }
    }

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
    /// Bumped whenever playback is interrupted, so completion callbacks from old segments are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    private static let volumeKey = "playerVolume"
    private static let loopingKey = "playerLooping"

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
        let frameCount = AVAudioFrameCount(max(0, audioFile.length - startFrame))
        guard frameCount > 0 else { return }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            lastError = "The audio output couldn’t be started."
            return
        }

        generation += 1
        let scheduledGeneration = generation
        segmentStartFrame = startFrame
        playerNode.scheduleSegment(
            audioFile, startingFrame: startFrame, frameCount: frameCount, at: nil,
            completionCallbackType: .dataPlayedBack
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.segmentFinished(scheduledGeneration) }
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

    private func segmentFinished(_ finishedGeneration: Int) {
        guard finishedGeneration == generation, isPlaying else { return }
        if isLooping {
            startPlayback(at: 0)
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
