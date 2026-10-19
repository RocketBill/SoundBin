import Foundation
import Observation
import Sparkle

/// Keeps SoundBin up to date using Sparkle. New versions are published as GitHub releases, and the
/// feed's address and signing key live in Info.plist (see Tools/release.sh).
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate: (any SPUUpdaterDelegate)?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// False while a check or update is already under way.
    private(set) var canCheckForUpdates = false

    init(delegate: (any SPUUpdaterDelegate)? = nil) {
        self.delegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        // Sparkle changes this on the main thread.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    private var updater: SPUUpdater { controller.updater }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// False when updates can't be installed without asking, e.g. the app is in a folder the user can't write to.
    var allowsAutomaticUpdates: Bool { updater.allowsAutomaticUpdates }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    /// Checks now and shows Sparkle's window with the result, including "you're up to date".
    func checkForUpdates() {
        // Sparkle refuses to update from these places; explain how to fix it instead of showing its error.
        if let problem = InstallLocation.problem {
            InstallLocation.showAlert(for: problem)
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Checks without showing anything unless an update is found.
    func checkForUpdatesInBackground() {
        updater.checkForUpdatesInBackground()
    }
}
