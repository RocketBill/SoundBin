import Foundation

/// A playable audio file discovered while scanning a folder.
nonisolated struct AudioFile: Identifiable, Hashable, Sendable {
    let url: URL
    /// Path of the containing folder relative to the browsed root. Empty for files at the root.
    let folder: String
    let fileSize: Int64
    let modificationDate: Date
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    /// File name without its extension; the format is shown separately.
    /// Name and format are stored because sorting compares them constantly, and deriving them from
    /// the URL each time makes sorting several times slower.
    let displayName: String
    let formatName: String

    init(url: URL, folder: String, fileSize: Int64, modificationDate: Date,
         duration: TimeInterval, sampleRate: Double, channelCount: Int) {
        self.url = url
        self.folder = folder
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        displayName = url.deletingPathExtension().lastPathComponent
        formatName = AudioFile.formatName(forExtension: url.pathExtension)
    }

    var id: URL { url }

    /// The same file grouped under a different folder.
    func inFolder(_ folder: String) -> AudioFile {
        guard folder != self.folder else { return self }
        return AudioFile(url: url, folder: folder, fileSize: fileSize, modificationDate: modificationDate,
                         duration: duration, sampleRate: sampleRate, channelCount: channelCount)
    }

    /// Short secondary line shown under a tile, e.g. "1.2s · WAV · 44.1 kHz".
    var summary: String {
        [Format.duration(duration), formatName, Format.sampleRate(sampleRate)].joined(separator: " · ")
    }

    static func formatName(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "wav", "wave", "bwf": "WAV"
        case "aif", "aiff", "aifc": "AIFF"
        case "m4a", "mp4", "aac": "AAC"
        default: ext.uppercased()
        }
    }
}

/// Listings are cached on disk, so revisiting a folder doesn't mean reading every file again.
extension AudioFile: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, folder, fileSize, modificationDate, duration, sampleRate, channelCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(URL.self, forKey: .url),
            folder: try container.decode(String.self, forKey: .folder),
            fileSize: try container.decode(Int64.self, forKey: .fileSize),
            modificationDate: try container.decode(Date.self, forKey: .modificationDate),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            sampleRate: try container.decode(Double.self, forKey: .sampleRate),
            channelCount: try container.decode(Int.self, forKey: .channelCount)
        )
    }
}

/// A group of files shown under one header in the grid. Groups map to subfolders of the browsed folder.
nonisolated struct FileSection: Identifiable, Hashable, Sendable {
    /// Relative folder path, which is unique within a listing.
    let id: String
    let title: String
    var files: [AudioFile]
    /// Number of files matching the current search, even when the section is collapsed.
    var matchCount: Int
    var isCollapsed: Bool
}

nonisolated enum SortKey: String, CaseIterable, Identifiable, Sendable {
    case name, duration, dateModified, size, format

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .duration: "Length"
        case .dateModified: "Date Modified"
        case .size: "Size"
        case .format: "Format"
        }
    }
}
