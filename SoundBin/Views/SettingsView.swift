import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @AppStorage(Preferences.playOnArrowKeys) private var playOnArrowKeys = true
    @State private var cacheSize: Int64?

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater

        Form {
            Section {
                Toggle("Show embedded artwork", isOn: $model.showsArtwork)
            } header: {
                Text("Grid")
            } footer: {
                Text("Some files, such as MP3s and M4As, carry cover art. It fills the tile, with the waveform in a strip along the bottom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                Toggle("Play sounds when clicked", isOn: $model.playOnClick)
                Toggle("Play sounds when moving through them with the arrow keys", isOn: $playOnArrowKeys)
            }

            Section {
                LabeledContent("Waveform and artwork cache") {
                    HStack {
                        if let cacheSize {
                            Text(cacheSize.formatted(.byteCount(style: .file)))
                                .foregroundStyle(.secondary)
                        }
                        Button("Clear") {
                            model.clearCaches()
                            cacheSize = 0
                        }
                    }
                }
            } footer: {
                Text("Waveforms and artwork are saved so folders open instantly next time. Clearing them is safe; they’re rebuilt as needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)
                LabeledContent("SoundBin \(Self.version)") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                if let checked = updater.lastUpdateCheckDate {
                    Text("Last checked \(checked.formatted(.relative(presentation: .named))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            cacheSize = await model.cacheSize()
        }
    }

    /// e.g. "1.2 (14)".
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
