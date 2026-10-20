import AVFoundation

/// Decodes a sound file to float PCM. Stands in for `AVAudioFile`, which mishandles Ogg Vorbis.
///
/// Core Audio positions Vorbis audio by its own count of the frames in each packet, and the count is wrong.
/// It skips 128 or more real frames at the start as if they were encoder priming, and lands seeks up to
/// ~20 ms late. A short click can lose almost all of its sound. So Vorbis files are decoded packet by
/// packet with exact positions (see `VorbisDecoder`), and every other format reads exactly as `AVAudioFile` would.
nonisolated final class AudioFileReader {
    /// Deinterleaved Float32 at the file's own sample rate and channel layout, as `AVAudioFile` reads it.
    let processingFormat: AVAudioFormat
    /// Frames in the file, at `processingFormat`'s sample rate.
    let length: AVAudioFramePosition

    private enum Decoder {
        case vorbis(VorbisDecoder)
        case extAudioFile(ExtAudioFileRef)
    }

    private let file: AudioFileID
    private let decoder: Decoder

    /// Core Audio's format ID for Vorbis, 'vorb'. There's no public constant for it.
    private static let vorbisFormatID: AudioFormatID = 0x766F_7262

    init(forReading url: URL) throws {
        var opened: AudioFileID?
        try CoreAudioCall.check(AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened))
        guard let opened else { throw CoreAudioCall.error(kAudioFileUnspecifiedError) }
        do {
            let dataFormat = try CoreAudioCall.property(AudioStreamBasicDescription()) {
                AudioFileGetProperty(opened, kAudioFilePropertyDataFormat, &$0, $1)
            }
            let isVorbis = dataFormat.mFormatID == Self.vorbisFormatID
            if isVorbis,
               let format = Self.processingFormat(for: dataFormat, layout: CoreAudioCall.channelLayout(
                   size: { AudioFileGetPropertyInfo(opened, kAudioFilePropertyChannelLayout, &$0, nil) },
                   { AudioFileGetProperty(opened, kAudioFilePropertyChannelLayout, &$0, $1) }
               )),
               let vorbis = VorbisDecoder(file: opened, fileFormat: dataFormat, outputFormat: format, url: url) {
                processingFormat = format
                length = vorbis.frameCount
                decoder = .vorbis(vorbis)
            } else {
                let wrapped = try Self.wrap(opened, keepingFirstFrames: isVorbis)
                processingFormat = wrapped.format
                length = wrapped.length
                decoder = .extAudioFile(wrapped.file)
            }
        } catch {
            AudioFileClose(opened)
            throw error
        }
        file = opened
    }

    deinit {
        if case .extAudioFile(let wrapped) = decoder {
            ExtAudioFileDispose(wrapped)
        }
        AudioFileClose(file)
    }

    /// The next frame `read` will return.
    var framePosition: AVAudioFramePosition {
        get {
            switch decoder {
            case .vorbis(let vorbis):
                return vorbis.position
            case .extAudioFile(let wrapped):
                var position: Int64 = 0
                ExtAudioFileTell(wrapped, &position)
                return position
            }
        }
        set {
            switch decoder {
            case .vorbis(let vorbis): vorbis.seek(to: newValue)
            case .extAudioFile(let wrapped): ExtAudioFileSeek(wrapped, newValue)
            }
        }
    }

    /// Fills `buffer` with up to `frameCount` frames (its whole capacity if nil). A `frameLength` of zero means the end.
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount? = nil) throws {
        var frames = min(frameCount ?? buffer.frameCapacity, buffer.frameCapacity)
        let status = switch decoder {
        case .vorbis(let vorbis): vorbis.read(into: buffer, frames: &frames)
        case .extAudioFile(let wrapped): ExtAudioFileRead(wrapped, &frames, buffer.bufferList(receiving: frames))
        }
        buffer.frameLength = status == noErr ? frames : 0
        try CoreAudioCall.check(status)
    }

    // MARK: Setup

    /// Reads `file` through `ExtAudioFile`, as `AVAudioFile` does.
    private static func wrap(_ file: AudioFileID, keepingFirstFrames isVorbis: Bool) throws
        -> (file: ExtAudioFileRef, format: AVAudioFormat, length: AVAudioFramePosition) {
        var opened: ExtAudioFileRef?
        try CoreAudioCall.check(ExtAudioFileWrapAudioFileID(file, false, &opened))
        guard let opened else { throw CoreAudioCall.error(kAudioFileUnspecifiedError) }
        do {
            let fileFormat = try CoreAudioCall.property(AudioStreamBasicDescription()) {
                ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &$0, $1)
            }
            if isVorbis {
                // If Core Audio won't take the change, the file still opens and plays, trimmed as before.
                try? keepFirstFrames(opened)
            }
            let layout = CoreAudioCall.channelLayout(
                size: { ExtAudioFileGetPropertyInfo(opened, kExtAudioFileProperty_FileChannelLayout, &$0, nil) },
                { ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileChannelLayout, &$0, $1) }
            )
            guard let format = processingFormat(for: fileFormat, layout: layout) else {
                throw CoreAudioCall.error(kAudioFileUnsupportedDataFormatError)
            }
            try CoreAudioCall.setProperty(format.streamDescription.pointee) {
                ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat, $0, $1)
            }
            let length = try CoreAudioCall.property(Int64(0)) {
                ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &$0, $1)
            }
            return (opened, format, length)
        } catch {
            ExtAudioFileDispose(opened)
            throw error
        }
    }

    /// For Vorbis files `VorbisDecoder` can't lay out: stops `ExtAudioFile` skipping real frames at the start,
    /// so the whole sound still plays. Its length then falls short of what it reads, and seeks stay approximate.
    private static func keepFirstFrames(_ file: ExtAudioFileRef) throws {
        var table = try CoreAudioCall.property(AudioFilePacketTableInfo()) {
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_PacketTable, &$0, $1)
        }
        table.mNumberValidFrames += Int64(table.mPrimingFrames)
        table.mPrimingFrames = 0
        try CoreAudioCall.setProperty(table) {
            ExtAudioFileSetProperty(file, kExtAudioFileProperty_PacketTable, $0, $1)
        }
    }

    private static func processingFormat(for fileFormat: AudioStreamBasicDescription, layout: AVAudioChannelLayout?) -> AVAudioFormat? {
        let channels = AVAudioChannelCount(fileFormat.mChannelsPerFrame)
        guard fileFormat.mSampleRate > 0, channels > 0 else { return nil }
        if channels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: fileFormat.mSampleRate, channels: channels)
        }
        // Formats with more than two channels need a layout.
        let layout = layout.flatMap { $0.channelCount == channels ? $0 : nil }
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        return layout.map { AVAudioFormat(standardFormatWithSampleRate: fileFormat.mSampleRate, channelLayout: $0) }
    }
}

nonisolated extension AVAudioPCMBuffer {
    /// The buffer list, sized to receive `frames`. Each access to `mutableAudioBufferList` resizes it to
    /// `frameLength`, so fill this one rather than fetching it again.
    func bufferList(receiving frames: AVAudioFrameCount) -> UnsafeMutablePointer<AudioBufferList> {
        let list = mutableAudioBufferList
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for index in buffers.indices {
            buffers[index].mDataByteSize = frames * bytesPerFrame
        }
        return list
    }
}

/// Throwing access to Core Audio properties. Each takes the call to make, which receives the size and storage.
nonisolated enum CoreAudioCall {
    static func property<Value: BitwiseCopyable>(
        _ initial: Value, _ get: (inout UInt32, UnsafeMutableRawPointer) -> OSStatus
    ) throws -> Value {
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        try check(withUnsafeMutableBytes(of: &value) { get(&size, $0.baseAddress!) })
        return value
    }

    static func setProperty<Value: BitwiseCopyable>(
        _ value: Value, _ set: (UInt32, UnsafeRawPointer) -> OSStatus
    ) throws {
        try check(withUnsafeBytes(of: value) { set(UInt32($0.count), $0.baseAddress!) })
    }

    /// A variable-length property: `size` reports its byte count, then `get` fills that many bytes.
    static func data(
        size: (inout UInt32) -> OSStatus, _ get: (inout UInt32, UnsafeMutableRawPointer) -> OSStatus
    ) throws -> Data {
        var count: UInt32 = 0
        try check(size(&count))
        guard count > 0 else { return Data() }
        var data = Data(count: Int(count))
        try data.withUnsafeMutableBytes { try check(get(&count, $0.baseAddress!)) }
        data.count = Int(count)
        return data
    }

    static func channelLayout(
        size: (inout UInt32) -> OSStatus, _ get: (inout UInt32, UnsafeMutableRawPointer) -> OSStatus
    ) -> AVAudioChannelLayout? {
        guard var data = try? data(size: size, get), !data.isEmpty else { return nil }
        // A layout given by a tag alone is shorter than the struct, which has room for one channel description.
        if data.count < MemoryLayout<AudioChannelLayout>.size {
            data.append(Data(count: MemoryLayout<AudioChannelLayout>.size - data.count))
        }
        return data.withUnsafeBytes {
            AVAudioChannelLayout(layout: $0.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self))
        }
    }

    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw error(status) }
    }

    static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
