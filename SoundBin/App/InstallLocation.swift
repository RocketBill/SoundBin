import AppKit

/// Detects when SoundBin is running from somewhere it can't update itself. Sparkle won't replace an app
/// that macOS is running from a temporary copy (opened straight from Downloads) or from its disk image.
enum InstallLocation {
    enum Problem {
        /// Opened from the folder it was downloaded to, so macOS is running a temporary copy of it.
        case downloadFolder
        /// Opened from its disk image, or another read-only volume.
        case diskImage
    }

    static var problem: Problem? {
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") { return .downloadFolder }
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return .diskImage }
        return nil
    }

    /// Explains how to install SoundBin properly. Quit ends the app so it can be moved; Not Now carries on.
    static func showAlert(for problem: Problem) {
        let alert = NSAlert()
        alert.messageText = "Move SoundBin to your Applications folder"
        alert.informativeText = switch problem {
        case .downloadFolder:
            "SoundBin is running from the folder it was downloaded to, so it can’t update itself. Quit SoundBin, drag it into your Applications folder, and open it from there."
        case .diskImage:
            "SoundBin is running from its disk image, so it can’t update itself. Quit SoundBin, drag it into your Applications folder, and open it from there."
        }
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
