import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Cover art embedded in an audio file, already shrunk to tile size. `image` is nil when the file has none.
nonisolated struct Artwork: @unchecked Sendable {
    // CGImage is immutable and safe to share between threads.
    let image: CGImage?

    static let none = Artwork(image: nil)
}

// MARK: - Extraction

nonisolated enum ArtworkExtractor {
    /// The raw bytes of the first embedded picture, if any.
    static func imageData(in url: URL) async -> Data? {
        // AVFoundation reads ID3 (MP3, AIFF, WAV) and MP4 cover atoms, but not FLAC picture blocks.
        if url.pathExtension.lowercased() == "flac" {
            return flacPicture(at: url)
        }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// Walks a FLAC file's metadata blocks looking for a PICTURE block (type 6).
    static func flacPicture(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }

        var isLastBlock = false
        while !isLastBlock {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let bytes = [UInt8](header)
            isLastBlock = bytes[0] & 0x80 != 0
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            if bytes[0] & 0x7F == 6 {
                guard let block = try? handle.read(upToCount: length), block.count == length else { return nil }
                return pictureData(fromFLACBlock: [UInt8](block))
            }
            guard let offset = try? handle.offset() else { return nil }
            try? handle.seek(toOffset: offset + UInt64(length))
        }
        return nil
    }

    /// PICTURE layout: type, MIME length + MIME, description length + description,
    /// width, height, depth, colour count, data length + data. All integers are 32-bit big-endian.
    private static func pictureData(fromFLACBlock block: [UInt8]) -> Data? {
        var position = 0
        func readLength() -> Int? {
            guard position + 4 <= block.count else { return nil }
            defer { position += 4 }
            return block[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        guard readLength() != nil, let mimeLength = readLength() else { return nil }
        position += mimeLength
        guard let descriptionLength = readLength() else { return nil }
        position += descriptionLength + 16
        guard let dataLength = readLength(), position + dataLength <= block.count else { return nil }
        return Data(block[position..<position + dataLength])
    }
}

// MARK: - Cache

/// Artwork is shrunk once and stored as a JPEG; files without artwork get an empty marker so they
/// aren't re-parsed every launch.
nonisolated enum ArtworkCache {
    static let directory = CacheDirectory("Artwork")

    /// Big enough for the largest tile on a Retina display.
    private static let maxPixelSize = 640

    static func load(_ key: FileKey) async -> Artwork? {
        let marker = directory.file(for: key, extension: "none")
        let jpeg = directory.file(for: key, extension: "jpg")
        if FileManager.default.fileExists(atPath: marker.path) { return Artwork.none }
        if let image = decodeCached(jpeg) { return Artwork(image: image) }

        // Unreadable usually means sandbox access has ended; return nil so it isn't recorded as "no artwork".
        guard FileManager.default.isReadableFile(atPath: key.url.path) else { return nil }
        guard let data = await ArtworkExtractor.imageData(in: key.url),
              let image = thumbnail(from: data)
        else {
            FileManager.default.createFile(atPath: marker.path, contents: nil)
            return Artwork.none
        }
        write(image, to: jpeg)
        return Artwork(image: image)
    }

    /// Decodes and downsamples in one step, so multi-megapixel covers never sit in memory at full size.
    private static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func decodeCached(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Decode now, on this background thread, rather than lazily on the main thread at first draw.
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
