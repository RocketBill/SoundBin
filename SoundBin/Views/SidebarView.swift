import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let library = model.library

        List(selection: $model.source) {
            Section("Library") {
                Label("Favourites", systemImage: "star")
                    .badge(library.favourites.count)
                    .tag(BrowseSource.favourites)
            }

            Section("Folders") {
                ForEach(library.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(folder.soundCount ?? 0)
                        .tag(BrowseSource.folder(folder.id))
                        .help(folder.path)
                        .contextMenu {
                            Button("Show in Finder", systemImage: "folder") {
                                model.revealFolder(folder)
                            }
                            Divider()
                            Button("Remove from Sidebar", systemImage: "minus.circle") {
                                model.removeFolder(folder.id)
                            }
                        }
                }
                .onMove { library.moveFolders(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Add Folder…", systemImage: "plus") {
                    model.presentOpenPanel()
                }
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
