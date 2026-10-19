import SwiftUI

struct SoundBinCommands: Commands {
    let model: AppModel
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(before: .sidebar) {
            Toggle("Include Subfolders", isOn: Bindable(model).includeSubfolders)
                .disabled(model.source == .favourites)
            Toggle("Show Artwork", isOn: Bindable(model).showsArtwork)
            Picker("Sort By", selection: Bindable(model).sortKey) {
                ForEach(SortKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            Picker("Sort Order", selection: Bindable(model).sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            Divider()
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-")
            Divider()
            Button("Reload Folder") { model.rescan() }
                .keyboardShortcut("r")
                .disabled(model.source == nil)
            Divider()
        }

        CommandMenu("Sound") {
            let selected = model.selectedFiles
            let player = model.player
            let isPlayingSelection = player.isPlaying && selected.contains { $0.id == player.currentFile?.id }

            Button(isPlayingSelection ? "Stop" : "Play") { model.togglePlaybackForSelection() }
                .disabled(selected.isEmpty && player.currentFile == nil)
            Toggle("Loop", isOn: Bindable(player).isLooping)
                .keyboardShortcut("l")
            Toggle("Play on Click", isOn: Bindable(model).playOnClick)
            Divider()
            Button(!selected.isEmpty && selected.allSatisfy(model.isFavourite) ? "Remove from Favourites" : "Add to Favourites") {
                model.toggleFavourite(selected)
            }
            .disabled(selected.isEmpty)
            Button("Show in Finder") { model.revealInFinder(selected) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selected.isEmpty)
        }
    }
}
