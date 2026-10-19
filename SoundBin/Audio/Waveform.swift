import Accelerate
import AVFoundation

/// A compact overview of a file's amplitude: one normalised peak per bucket.
nonisolated struct Waveform: Sendable {
    static let bucketCount = 512

    /// Peak magnitude per bucket, scaled so the loudest bucket is 255.
    let peaks: [UInt8]

    static let silent = Waveform(peaks: [UInt8](repeating: 0, count: bucketCount))

    /// Resamples the peaks to `count` bars in 0...1, keeping the loudest value of each span.
    func bars(count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        let source = peaks.count
        return (0..<count).map { index in
            let start = index * source / count
            let end = max(start + 1, (index + 1) * source / count)
            var loudest: UInt8 = 0
            for value in peaks[start..<min(end, source)] where value > loudest {
                loudest = value
            }
            return Float(loudest) / 255
        }
    }
}

// MARK: - Analysis

nonisolated enum WaveformAnalyzer {
    /// Files longer than this are sampled at each bucket instead of decoded end to end (~3 minutes at 48 kHz).
    private static let fullReadLimit: AVAudioFramePosition = 9_000_000
    private static let chunkSize: AVAudioFrameCount = 65_536
    private static let sampleWindow: AVAudioFrameCount = 4096

    static func analyze(_ url: URL) -> Waveform? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let length = file.length
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard length > 0, channelCount > 0 else { return .silent }

        let bucketCount = Waveform.bucketCount
        let framesPerBucket = Double(length) / Double(bucketCount)
        var peaks = [Float](repeating: 0, count: bucketCount)

        let capacity = length <= fullReadLimit ? chunkSize : sampleWindow
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        do {
            if length <= fullReadLimit {
                var position: AVAudioFramePosition = 0
                while position < length {
                    if Task.isCancelled { return nil }
                    try file.read(into: buffer, frameCount: chunkSize)
                    let count = Int(buffer.frameLength)
                    guard count > 0 else { break }
                    accumulate(buffer, frameCount: count, startFrame: position,
                               framesPerBucket: framesPerBucket, into: &peaks)
                    position += AVAudioFramePosition(count)
                }
            } else {
                for bucket in 0..<bucketCount {
                    if Task.isCancelled { return nil }
                    file.framePosition = AVAudioFramePosition(Double(bucket) * framesPerBucket)
                    try file.read(into: buffer, frameCount: sampleWindow)
                    peaks[bucket] = maxMagnitude(buffer, offset: 0, count: Int(buffer.frameLength))
                }
            }
        } catch {
            // Keep whatever was decoded before the error; a partial waveform beats none.
        }

        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return .silent }
        let scale = 255 / loudest
        return Waveform(peaks: peaks.map { UInt8(min(255, ($0 * scale).rounded())) })
    }

    /// Folds a decoded chunk into the per-bucket peaks, one vDSP call per bucket-sized run.
    private static func accumulate(
        _ buffer: AVAudioPCMBuffer,
        frameCount: Int,
        startFrame: AVAudioFramePosition,
        framesPerBucket: Double,
        into peaks: inout [Float]
    ) {
        let lastBucket = peaks.count - 1
        var offset = 0
        while offset < frameCount {
            let frame = Double(startFrame) + Double(offset)
            let bucket = min(lastBucket, Int(frame / framesPerBucket))
            let bucketEnd = Int((Double(bucket + 1) * framesPerBucket).rounded(.up)) - Int(startFrame)
            let runEnd = bucket == lastBucket ? frameCount : min(frameCount, bucketEnd)
            let run = max(1, runEnd - offset)
            peaks[bucket] = max(peaks[bucket], maxMagnitude(buffer, offset: offset, count: run))
            offset += run
        }
    }

    private static func maxMagnitude(_ buffer: AVAudioPCMBuffer, offset: Int, count: Int) -> Float {
        guard count > 0, let channels = buffer.floatChannelData else { return 0 }
        var loudest: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var value: Float = 0
            vDSP_maxmgv(channels[channel] + offset, 1, &value, vDSP_Length(count))
            loudest = max(loudest, value)
        }
        return loudest
    }
}

// MARK: - Cache

/// Waveforms are stored as tiny files (one byte per bucket) so folders open instantly next time.
nonisolated enum WaveformCache {
    static let directory = CacheDirectory("Waveforms")

    static func load(_ key: FileKey) async -> Waveform? {
        let location = directory.file(for: key, extension: "peaks")
        if let data = try? Data(contentsOf: location), data.count == Waveform.bucketCount {
            return Waveform(peaks: [UInt8](data))
        }
        guard let waveform = WaveformAnalyzer.analyze(key.url) else { return nil }
        try? Data(waveform.peaks).write(to: location, options: .atomic)
        return waveform
    }
}
