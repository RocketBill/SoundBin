import SwiftUI

struct SoundBinCommands: Commands {
    let model: AppModel
    let updater: Updater

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SoundBin") { AboutPanel.show() }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Collection") { model.newCollection() }
                .keyboardShortcut("n")
            Button("New Collection with Selection") { model.newCollection(with: model.selectedFiles) }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Open Folder…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(before: .sidebar) {
            Toggle("Include Subfolders", isOn: Bindable(model).includeSubfolders)
                .disabled(model.source?.isFileList == true)
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
            Toggle("Play Next Automatically", isOn: Bindable(player).playsNext)
            Toggle("Play on Click", isOn: Bindable(model).playOnClick)
            Divider()
            Button(!selected.isEmpty && selected.allSatisfy(model.isFavourite) ? "Remove from Favourites" : "Add to Favourites") {
                model.toggleFavourite(selected)
            }
            .disabled(selected.isEmpty)
            Menu("Add to Collection") {
                ForEach(model.library.collections) { collection in
                    Button(collection.name) { model.addToCollection(selected.map(\.url), collection.id) }
                        .disabled(model.source == .collection(collection.id))
                }
                if !model.library.collections.isEmpty { Divider() }
                Button("New Collection with Selection") { model.newCollection(with: selected) }
            }
            .disabled(selected.isEmpty)
            if case .collection = model.source {
                Button("Rename") { model.renamingSound = selected.first?.url }
                    .disabled(selected.count != 1)
                Button("Remove from Collection") { model.removeFromCollection(selected) }
                    .disabled(selected.isEmpty)
            }
            Menu("Label") {
                ForEach(SoundLabel.allCases) { label in
                    Toggle(isOn: Binding(
                        get: { !selected.isEmpty && selected.allSatisfy { model.labels(of: $0).contains(label) } },
                        set: { _ in model.toggleLabel(label, for: selected) }
                    )) {
                        Label { Text(model.library.name(of: label)) } icon: { Image(nsImage: label.dot) }
                    }
                    .keyboardShortcut(KeyEquivalent(label.shortcutDigit), modifiers: [.command, .option])
                }
                Divider()
                Button("Remove All Labels") { model.clearLabels(for: selected) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
            .disabled(selected.isEmpty)
            Divider()
            Button("Show in Finder") { model.revealInFinder(selected) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selected.isEmpty)
        }
    }
}

/// The standard About window, with a credit line under the version.
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: "Developed by RocketBill", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
