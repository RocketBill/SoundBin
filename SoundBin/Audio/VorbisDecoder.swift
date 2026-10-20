import AVFoundation

/// Decodes Ogg Vorbis packet by packet with an `AudioConverter`, keeping every frame and seeking exactly.
///
/// Core Audio decodes each packet correctly but is wrong about which frames a packet produces (see
/// `AudioFileReader`), so positions come from `OggVorbisLayout` instead. After a reset the decoder's first
/// packet only primes it, so a seek starts one audio packet before the target and discards frames up to it.
nonisolated final class VorbisDecoder {
    /// Every frame the file decodes to.
    let frameCount: AVAudioFramePosition
    /// The next frame `read` will return.
    private(set) var position: AVAudioFramePosition = 0

    private let file: AudioFileID
    private let inputFormat: AudioStreamBasicDescription
    private let outputFormat: AVAudioFormat
    private let cookie: Data
    /// Made on first use, since the folder scanner opens files only to learn their length.
    private var converter: AudioConverterRef?
    private let packetStarts: [AVAudioFramePosition]
    private let channelCount: UInt32
    private let packetData: UnsafeMutableRawPointer
    private let packetCapacity: UInt32
    private let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>
    private var nextPacket = 0
    /// Frames to decode and throw away after a seek, before `read` returns any.
    private var framesToSkip: AVAudioFramePosition = 0

    /// Returns nil if the file's packets can't be laid out, so the caller can fall back to `ExtAudioFile`.
    /// `file` must stay open for as long as the decoder is used.
    init?(file: AudioFileID, fileFormat: AudioStreamBasicDescription, outputFormat: AVAudioFormat, url: URL) {
        guard let layout = OggVorbisLayout(url: url), layout.frameCount > 0,
              let packetCount = try? CoreAudioCall.property(UInt64(0), {
                  AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &$0, $1)
              }),
              packetCount == layout.packetStarts.count,
              let cookie = try? CoreAudioCall.data(
                  size: { AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &$0, nil) },
                  { AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &$0, $1) }
              ),
              !cookie.isEmpty
        else { return nil }

        self.file = file
        inputFormat = fileFormat
        self.outputFormat = outputFormat
        self.cookie = cookie
        packetStarts = layout.packetStarts
        frameCount = layout.frameCount
        channelCount = fileFormat.mChannelsPerFrame
        // Sized from the file itself: Core Audio reads a packet that doesn't fit as no packet at all,
        // just as it reads an empty one.
        packetCapacity = UInt32(layout.largestPacket)
        packetData = .allocate(byteCount: layout.largestPacket, alignment: 16)
        packetDescription = .allocate(capacity: 1)
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
        packetData.deallocate()
        packetDescription.deallocate()
    }

    /// Fills `buffer` with up to `frames` frames, setting `frames` to how many it got. Zero means the end.
    func read(into buffer: AVAudioPCMBuffer, frames: inout AVAudioFrameCount) -> OSStatus {
        while framesToSkip > 0 {
            var skipped = AVAudioFrameCount(min(framesToSkip, AVAudioFramePosition(buffer.frameCapacity)))
            let status = decode(into: buffer, frames: &skipped)
            guard status == noErr else { return status }
            framesToSkip = skipped > 0 ? framesToSkip - AVAudioFramePosition(skipped) : 0
        }
        let status = decode(into: buffer, frames: &frames)
        position += AVAudioFramePosition(status == noErr ? frames : 0)
        return status
    }

    func seek(to frame: AVAudioFramePosition) {
        let target = min(max(0, frame), frameCount)
        // Find the last packet whose frames start at or before the target. It's never the first, which
        // decodes to nothing.
        var low = 0
        var high = packetStarts.count
        while low < high {
            let middle = (low + high) / 2
            if packetStarts[middle] <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let packet = max(1, low - 1)
        // Prime with the closest packet before it that decodes audio. Empty packets decode to nothing and
        // leave the decoder as it was, so they can't. Starting from the first packet is always safe.
        var primer = packet - 1
        while primer > 0, packetStarts[primer + 1] == packetStarts[primer] {
            primer -= 1
        }
        if let converter {
            AudioConverterReset(converter)
        }
        nextPacket = primer
        framesToSkip = target - packetStarts[packet]
        position = target
    }

    private func decode(into buffer: AVAudioPCMBuffer, frames: inout AVAudioFrameCount) -> OSStatus {
        if converter == nil {
            let status = makeConverter()
            guard status == noErr else { return status }
        }
        guard let converter else { return kAudioConverterErr_UnspecifiedError }
        return AudioConverterFillComplexBuffer(converter, { _, packetCount, data, description, context in
            guard let context else { return kAudio_ParamError }
            return Unmanaged<VorbisDecoder>.fromOpaque(context).takeUnretainedValue()
                .supplyPacket(count: packetCount, data: data, description: description)
        }, Unmanaged.passUnretained(self).toOpaque(), &frames, buffer.bufferList(receiving: frames), nil)
    }

    private func makeConverter() -> OSStatus {
        var input = inputFormat
        var created: AudioConverterRef?
        var status = AudioConverterNew(&input, outputFormat.streamDescription, &created)
        guard status == noErr, let created else { return status == noErr ? kAudioConverterErr_UnspecifiedError : status }
        status = cookie.withUnsafeBytes {
            AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
        }
        guard status == noErr else {
            AudioConverterDispose(created)
            return status
        }
        converter = created
        return noErr
    }

    /// Hands the converter the next packet, or none at the end of the file.
    private func supplyPacket(
        count: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutablePointer<AudioBufferList>,
        description: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        count.pointee = 0
        var bytes: UInt32 = 0
        var packets: UInt32 = 0
        // An empty packet reads as no packet. It decodes to nothing, so move on to the next. Passing
        // the converter no packet would end the file there.
        while packets == 0 {
            guard nextPacket < packetStarts.count else { return noErr }
            bytes = packetCapacity
            packets = 1
            let status = AudioFileReadPacketData(file, false, &bytes, packetDescription, Int64(nextPacket), &packets, packetData)
            guard status == noErr else { return status }
            nextPacket += 1
        }
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: channelCount, mDataByteSize: bytes, mData: packetData)
        description?.pointee = packetDescription
        count.pointee = 1
        return noErr
    }
}
