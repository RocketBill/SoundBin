import AppKit

/// Copies a collection's sounds into a new folder on disk, for "Make Real Folder".
nonisolated enum CollectionCopier {
    /// Creates `folder` and copies `files` into it. Same-named files are numbered as Finder would ("Kick 2.wav").
    /// Returns the names of files that couldn't be copied, or fails if the folder itself couldn't be made.
    /// `progress` receives the fraction done, from 0 to 1.
    @concurrent
    static func copy(_ files: [URL], into folder: URL,
                     progress: @escaping @Sendable (Double) -> Void) async -> Result<[String], any Error> {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            return .failure(error)
        }

        var failed: [String] = []
        var taken: Set<String> = []
        var reported = 0.0
        for (index, source) in files.enumerated() {
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }

            let name = uniqueName(for: source.lastPathComponent, taken: &taken)
            do {
                // On APFS this makes a clone, so copies on the same disk are instant and take no extra space.
                try manager.copyItem(at: source, to: folder.appending(path: name))
            } catch {
                failed.append(source.lastPathComponent)
            }

            let fraction = Double(index + 1) / Double(files.count)
            if fraction - reported >= 0.01 || index == files.count - 1 {
                reported = fraction
                progress(fraction)
            }
        }
        return .success(failed)
    }

    /// Names are compared case-insensitively, as most Mac disks treat "Kick.wav" and "kick.wav" as the same file.
    private static func uniqueName(for name: String, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

/// Stops the "Make Real Folder" panel from choosing a name that's already in use, rather than offering to replace it.
final class NewFolderValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        throw CocoaError(.fileWriteFileExists, userInfo: [
            NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” already exists. Choose a different name.",
        ])
    }
}
