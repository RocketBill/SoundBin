import Foundation

/// Where the frames of an Ogg Vorbis file fall, worked out from its packet headers without decoding audio.
///
/// Core Audio miscounts Vorbis frames (see `AudioFileReader`), so this counts them the way the decoder
/// produces them: each audio packet after the first yields a quarter of its own block size plus a quarter
/// of the previous packet's. The sound ends where the last page's granule position says.
nonisolated struct OggVorbisLayout {
    /// The first frame each audio packet decodes to, in file order. The first packet only primes the
    /// decoder, so it and the second both start at zero.
    let packetStarts: [Int64]
    /// Frames in the sound. The decoder produces more if the final granule position cuts the last packet short;
    /// those are padding the encoder made up to fill the last block, and aren't part of the sound.
    let frameCount: Int64
    /// Bytes in the largest audio packet.
    let largestPacket: Int
    /// Empty packets at the very end, which some encoders write to end the stream. They decode to nothing,
    /// and Core Audio leaves them out of its packet count.
    let trailingEmptyPackets: Int

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let layout = data.withUnsafeBytes({ Self.parse($0) }) else { return nil }
        self = layout
    }

    private init(packetStarts: [Int64], frameCount: Int64, largestPacket: Int, trailingEmptyPackets: Int) {
        self.packetStarts = packetStarts
        self.frameCount = frameCount
        self.largestPacket = largestPacket
        self.trailingEmptyPackets = trailingEmptyPackets
    }

    // MARK: Parsing

    private static func parse(_ bytes: UnsafeRawBufferPointer) -> OggVorbisLayout? {
        var stream = PacketStream()
        var offset = 0
        var serial: UInt32?
        // The latest granule position, and the frames decoded up to it.
        var lastGranule: (position: Int64, frames: Int64) = (0, 0)
        var endFrame: Int64?
        while offset + 27 <= bytes.count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                return nil
            }
            let isLastPage = bytes[offset + 5] & 0x04 != 0
            let granule = bytes.loadUnaligned(fromByteOffset: offset + 6, as: Int64.self).littleEndian
            let pageSerial = bytes.loadUnaligned(fromByteOffset: offset + 14, as: UInt32.self).littleEndian
            let segmentCount = Int(bytes[offset + 26])
            let tableStart = offset + 27
            guard tableStart + segmentCount <= bytes.count else { return nil }
            let lacing = bytes[tableStart..<(tableStart + segmentCount)]
            let bodyLength = lacing.reduce(0) { $0 + Int($1) }
            var segmentStart = tableStart + segmentCount
            guard segmentStart + bodyLength <= bytes.count else { return nil }

            // Only the first logical stream is played, so ignore any others multiplexed or chained after it.
            if serial == nil { serial = pageSerial }
            if pageSerial == serial {
                for length in lacing {
                    let segment = UnsafeRawBufferPointer(rebasing: bytes[segmentStart..<(segmentStart + Int(length))])
                    guard stream.append(segment, endsPacket: length < 255) else { return nil }
                    segmentStart += Int(length)
                }
                // A page's granule position is the frame after the last packet that ends on it, or -1 if none does.
                if granule >= 0 {
                    if isLastPage {
                        // Measure from the granule position before, as libvorbis does, since some streams don't
                        // number their frames from zero. Only the last page's own frames can be cut, and wrapping
                        // arithmetic means a corrupt position can't crash.
                        let framesOnPage = stream.frameCount - lastGranule.frames
                        let excess = lastGranule.position &+ framesOnPage &- granule
                        endFrame = stream.frameCount - min(max(0, excess), framesOnPage)
                    }
                    lastGranule = (granule, stream.frameCount)
                }
                if isLastPage { break }
            }
            offset = tableStart + segmentCount + bodyLength
        }
        guard !stream.packetStarts.isEmpty else { return nil }
        return OggVorbisLayout(packetStarts: stream.packetStarts, frameCount: endFrame ?? stream.frameCount,
                               largestPacket: stream.largestPacket, trailingEmptyPackets: stream.trailingEmptyPackets)
    }

    /// Reassembles packets from page segments and counts the frames each audio packet decodes to.
    private struct PacketStream {
        private(set) var packetStarts: [Int64] = []
        private(set) var frameCount: Int64 = 0
        private(set) var largestPacket = 0
        private(set) var trailingEmptyPackets = 0

        private var packetIndex = 0
        /// Bytes of the packet being reassembled, kept only for the headers. Audio packets need just their first byte.
        private var header: [UInt8] = []
        private var firstByte: UInt8?
        private var packetLength = 0
        private var blockSizes: (short: Int64, long: Int64) = (0, 0)
        private var modeIsLong: [Bool] = []
        private var modeBits = 0
        private var previousBlockSize: Int64?

        mutating func append(_ segment: UnsafeRawBufferPointer, endsPacket: Bool) -> Bool {
            if firstByte == nil, let byte = segment.first {
                firstByte = byte
            }
            if packetIndex < 3 {
                header.append(contentsOf: segment)
            }
            packetLength += segment.count
            guard endsPacket else { return true }
            defer {
                packetIndex += 1
                header.removeAll()
                firstByte = nil
                packetLength = 0
            }
            switch packetIndex {
            case 0: return readIdentification()
            case 1: return true
            case 2: return readModes()
            default:
                countAudioPacket()
                largestPacket = max(largestPacket, packetLength)
                trailingEmptyPackets = packetLength == 0 ? trailingEmptyPackets + 1 : 0
                return true
            }
        }

        private mutating func readIdentification() -> Bool {
            guard header.count >= 30, header[0] == 1, header[1...6].elementsEqual("vorbis".utf8) else { return false }
            let sizes = header[28]
            blockSizes = (Int64(1) << (sizes & 0x0F), Int64(1) << (sizes >> 4))
            return blockSizes.short >= 64 && blockSizes.long >= blockSizes.short
        }

        /// Finds the modes at the end of the setup header by walking back from its framing bit, as FFmpeg
        /// does. Reading forward would mean parsing every codebook, floor and residue before them.
        private mutating func readModes() -> Bool {
            guard header.first == 5 else { return false }
            let bits = LSBBits(header)
            var end = bits.count - 1
            while end >= 0, bits.value(at: end, width: 1) == 0 {
                end -= 1
            }
            // Each mode is a block flag, a 16-bit window type, a 16-bit transform type (both always zero)
            // and an 8-bit mapping, and the list is preceded by a 6-bit count. Keep the longest run of
            // plausible modes whose count matches.
            var found: [Bool] = []
            var modeCount = 0
            while end - 41 - 6 >= 0, found.count < 64 {
                let mapping = bits.value(at: end - 8, width: 8)
                let transform = bits.value(at: end - 24, width: 16)
                let window = bits.value(at: end - 40, width: 16)
                guard window == 0, transform == 0, mapping < 64 else { break }
                found.append(bits.value(at: end - 41, width: 1) == 1)
                end -= 41
                if bits.value(at: end - 6, width: 6) + 1 == found.count {
                    modeCount = found.count
                }
            }
            guard modeCount > 0 else { return false }
            modeIsLong = Array(found.prefix(modeCount).reversed())
            modeBits = modeCount > 1 ? Int.bitWidth - (modeCount - 1).leadingZeroBitCount : 0
            return true
        }

        private mutating func countAudioPacket() {
            // Every packet gets an entry so indices match Core Audio's, but empty packets and anything
            // that isn't audio decode to nothing.
            packetStarts.append(frameCount)
            guard let byte = firstByte, byte & 1 == 0 else { return }
            let mode = Int(byte >> 1) & ((1 << modeBits) - 1)
            guard mode < modeIsLong.count else { return }
            let blockSize = modeIsLong[mode] ? blockSizes.long : blockSizes.short
            if let previousBlockSize {
                frameCount += (previousBlockSize + blockSize) / 4
            }
            previousBlockSize = blockSize
        }
    }

    /// Reads fields packed least significant bit first, as Vorbis packs them.
    private struct LSBBits {
        let bytes: [UInt8]
        var count: Int { bytes.count * 8 }

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        func value(at position: Int, width: Int) -> Int {
            var value = 0
            for bit in 0..<width {
                let index = position + bit
                if bytes[index / 8] >> (index % 8) & 1 == 1 {
                    value |= 1 << bit
                }
            }
            return value
        }
    }
}
