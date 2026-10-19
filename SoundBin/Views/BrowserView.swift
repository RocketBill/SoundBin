import SwiftUI

/// The detail column: the grid of sounds plus whatever empty state applies.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private static let transportClearance: CGFloat = 84

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.totalCount > 0 {
                SoundGridView(
                    model: model,
                    sections: model.sections,
                    version: model.sectionsVersion,
                    source: model.source,
                    tileWidth: model.tileSize,
                    showsHeaders: model.showsSectionHeaders,
                    showsArtwork: model.showsArtwork,
                    bottomInset: Self.transportClearance
                )
                // Scroll under the toolbar's glass, but start beside the sidebar rather than beneath it.
                .ignoresSafeArea(edges: .vertical)
            }
            placeholder
        }
        // Fill the column even when only a small placeholder shows, so the transport stays at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            TransportBar()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.source == nil {
            ContentUnavailableView {
                Label("No Folder Open", systemImage: "waveform")
            } description: {
                Text("Open a folder of sounds, or drag one here.")
            } actions: {
                Button("Open Folder…") { model.presentOpenPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if model.folderIsMissing {
            ContentUnavailableView {
                Label("Folder Not Found", systemImage: "questionmark.folder")
            } description: {
                Text("“\(model.rootTitle)” may have been moved, renamed or deleted.")
            } actions: {
                Button("Locate…") { model.presentOpenPanel() }
                if case .folder(let id) = model.source {
                    Button("Remove from Sidebar") { model.removeFolder(id) }
                }
            }
        } else if model.isScanning && model.totalCount == 0 {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(model.scannedCount > 0 ? "Reading \(Format.soundCount(model.scannedCount))…" : "Scanning…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if model.totalCount == 0 {
            if model.source == .favourites {
                ContentUnavailableView("No Favourites", systemImage: "star",
                                       description: Text("Click the star on a sound, or select it and press Full Stop."))
            } else if case .collection = model.source {
                ContentUnavailableView("No Sounds in This Collection", systemImage: "rectangle.stack",
                                       description: Text("Drag sounds here or onto the collection in the sidebar, or right-click a sound and choose Add to Collection."))
            } else {
                ContentUnavailableView("No Sounds", systemImage: "waveform.slash",
                                       description: Text("This folder doesn’t contain any audio files SoundBin can play."))
            }
        } else if model.sections.isEmpty {
            if model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
            } else if !model.labelFilter.isEmpty {
                ContentUnavailableView {
                    Label("No Labelled Sounds", systemImage: "circle.grid.2x1.fill")
                } description: {
                    Text("Nothing here has the labels you’re showing.")
                } actions: {
                    Button("Show All Sounds") { model.labelFilter = [] }
                }
            } else if model.subfoldersAreHidingEverything {
                ContentUnavailableView {
                    Label("All Sounds Are in Subfolders", systemImage: "folder")
                } description: {
                    Text("Include subfolders to see them.")
                } actions: {
                    Button("Include Subfolders") { model.includeSubfolders = true }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model

        ToolbarItem {
            Slider(value: $model.tileSize, in: AppModel.tileSizeRange) {
                Text("Tile Size")
            } minimumValueLabel: {
                Image(systemName: "square.grid.3x3")
                    .imageScale(.small)
            } maximumValueLabel: {
                Image(systemName: "square.grid.2x2")
                    .imageScale(.medium)
            }
            .frame(width: 140)
            // Breathing room between the end icons and the toolbar's glass capsule.
            .padding(.horizontal, 10)
            .help("Tile size")
            .disabled(model.totalCount == 0)
        }

        ToolbarItem {
            Menu {
                Toggle("Include Subfolders", isOn: $model.includeSubfolders)
                    .disabled(model.source?.isFileList == true)
                Divider()
                Picker("Sort By", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $model.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
                Section("Show Labels") {
                    ForEach(SoundLabel.allCases) { label in
                        Toggle(isOn: Binding(
                            get: { model.labelFilter.contains(label) },
                            set: { isOn in
                                if isOn { model.labelFilter.insert(label) } else { model.labelFilter.remove(label) }
                            }
                        )) {
                            Label { Text(model.library.name(of: label)) } icon: { Image(nsImage: label.dot) }
                        }
                    }
                    Button("Show All Sounds") { model.labelFilter = [] }
                        .disabled(model.labelFilter.isEmpty)
                    Button("Edit Labels…") {
                        UserDefaults.standard.set(SettingsView.Tab.labels.rawValue, forKey: SettingsView.tabKey)
                        openSettings()
                    }
                }
            } label: {
                // Filled while a label filter hides sounds, as Mail does.
                Label("Sort and Filter", systemImage: model.labelFilter.isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Sort and filter")
        }

        ToolbarItem {
            Button("Open Folder", systemImage: "folder.badge.plus") {
                model.presentOpenPanel()
            }
            .help("Open a folder (⌘O)")
        }
    }
}
