import SwiftUI

/// The detail column: the grid of sounds plus whatever empty state applies.
struct BrowserView: View {
    @Environment(AppModel.self) private var model

    private static let transportClearance: CGFloat = 84

    var body: some View {
        @Bindable var model = model
        let hasTransport = model.player.currentFile != nil

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
                    bottomInset: hasTransport ? Self.transportClearance : 0
                )
                .ignoresSafeArea()
            }
            placeholder
        }
        // Fill the column even when only a small placeholder shows, so the transport stays at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if hasTransport {
                TransportBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: hasTransport)
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
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
            } else {
                ContentUnavailableView("No Sounds", systemImage: "waveform.slash",
                                       description: Text("This folder doesn’t contain any audio files SoundBin can play."))
            }
        } else if model.sections.isEmpty {
            if model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
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
                    .disabled(model.source == .favourites)
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
            } label: {
                Label("Sort and Filter", systemImage: "line.3.horizontal.decrease")
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
