import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var collectionToDelete: SavedCollection?

    var body: some View {
        @Bindable var model = model
        let library = model.library

        List(selection: $model.source) {
            Section("Library") {
                Label("Favourites", systemImage: "star")
                    .badge(library.favourites.count)
                    .tag(BrowseSource.favourites)
            }

            if !library.collections.isEmpty {
                Section("Collections") {
                    ForEach(library.collections) { collection in
                        CollectionRow(collection: collection, onDelete: confirmDelete)
                            .tag(BrowseSource.collection(collection.id))
                    }
                    .onMove { library.moveCollections(from: $0, to: $1) }
                }
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
        .contextMenu {
            Button("New Collection", systemImage: "rectangle.stack.badge.plus") { model.newCollection() }
            Button("Add Folder…", systemImage: "folder.badge.plus") { model.presentOpenPanel() }
        }
        .onDeleteCommand {
            if case .collection(let id) = model.source, let collection = library.collection(id: id) {
                confirmDelete(collection)
            }
        }
        .confirmationDialog(
            "Delete “\(collectionToDelete?.name ?? "")”?",
            isPresented: Binding(get: { collectionToDelete != nil }, set: { if !$0 { collectionToDelete = nil } }),
            presenting: collectionToDelete
        ) { collection in
            Button("Delete Collection", role: .destructive) { model.deleteCollection(collection.id) }
        } message: { _ in
            Text("The sounds themselves won’t be deleted.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { model.presentOpenPanel() }
                    Button("New Collection", systemImage: "rectangle.stack.badge.plus") { model.newCollection() }
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// Empty collections go straight away; ones holding sounds ask first.
    private func confirmDelete(_ collection: SavedCollection) {
        guard model.folderCopyProgress[collection.id] == nil else { return }
        if collection.files.isEmpty {
            model.deleteCollection(collection.id)
        } else {
            collectionToDelete = collection
        }
    }
}

/// A collection in the sidebar. Sounds can be dropped on it, and its name edits in place.
private struct CollectionRow: View {
    let collection: SavedCollection
    let onDelete: (SavedCollection) -> Void

    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var isDropTarget = false
    @FocusState private var isEditing: Bool

    var body: some View {
        let copyProgress = model.folderCopyProgress[collection.id]

        Label {
            if model.renamingCollection == collection.id {
                TextField("Name", text: $draft)
                    .focused($isEditing)
                    .onSubmit(commitRename)
                    .onExitCommand { model.renamingCollection = nil }
                    .onChange(of: isEditing) { _, editing in
                        if !editing { commitRename() }
                    }
                    .onAppear {
                        draft = collection.name
                        isEditing = true
                    }
            } else {
                HStack {
                    Text(collection.name)
                    if let copyProgress {
                        Spacer()
                        ProgressView(value: copyProgress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .help("Making a real folder…")
                    }
                }
            }
        } icon: {
            Image(systemName: "rectangle.stack")
        }
        .badge(copyProgress == nil ? collection.files.count : 0)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.tint.opacity(0.25))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addToCollection(urls, collection.id)
        } isTargeted: {
            isDropTarget = $0
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                model.renamingCollection = collection.id
            }
            Button("Make Real Folder…", systemImage: "folder.badge.plus") {
                model.presentMakeRealFolder(collection.id)
            }
            .disabled(collection.files.isEmpty || copyProgress != nil)
            Divider()
            Button("Delete Collection", systemImage: "trash") {
                onDelete(collection)
            }
            .disabled(copyProgress != nil)
        }
    }

    private func commitRename() {
        guard model.renamingCollection == collection.id else { return }
        model.renameCollection(collection.id, to: draft)
        model.renamingCollection = nil
    }
}
