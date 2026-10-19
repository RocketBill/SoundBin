import SwiftUI

/// Settings in the standard tabbed window, one short pane per tab so none outgrows the screen.
struct SettingsView: View {
    enum Tab: String {
        case general, labels, updates
    }

    /// Shared with "Edit Labels…" in the filter menu, which opens Settings on the Labels tab.
    static let tabKey = "settingsTab"

    @AppStorage(SettingsView.tabKey) private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            LabelSettings()
                .tabItem { Label("Labels", systemImage: "circle.grid.2x2") }
                .tag(Tab.labels)
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.playOnArrowKeys) private var playOnArrowKeys = true
    @State private var cacheSize: Int64?

    var body: some View {
        @Bindable var model = model

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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            cacheSize = await model.cacheSize()
        }
    }
}

private struct LabelSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(SoundLabel.allCases) { label in
                    LabelNameField(label: label, library: model.library)
                }
            } footer: {
                Text("Name the colours after how you sort sounds, such as Kicks or Vocals. Leave a name empty to use the colour’s own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdateSettings: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater

        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)
                LabeledContent("SoundBin \(Self.version)") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } footer: {
                if let checked = updater.lastUpdateCheckDate {
                    Text("Last checked \(checked.formatted(.relative(presentation: .named))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// e.g. "1.2 (14)".
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// One label's name, saved when editing ends so half-typed names aren't stored as you go.
private struct LabelNameField: View {
    let label: SoundLabel
    let library: Library

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(text: $draft, prompt: Text(label.defaultName)) {
            Label { Text(label.defaultName) } icon: { Image(nsImage: label.dot) }
        }
        .focused($isFocused)
        .onSubmit(commit)
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onAppear {
            let name = library.name(of: label)
            draft = name == label.defaultName ? "" : name
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        library.renameLabel(label, to: draft.isEmpty ? label.defaultName : draft)
    }
}
