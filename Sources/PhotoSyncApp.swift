import SwiftUI
import Photos

@main
struct PhotoSyncApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct Album: Identifiable {
    let id: String
    let title: String
    let isUser: Bool          // true = created by you, false = default/smart album
    let collection: PHAssetCollection
}

enum Filter: String, CaseIterable { case all = "All", mine = "Created", defaults = "Default" }

struct ContentView: View {
    @State private var albums: [Album] = []
    @State private var selected = Set<String>()
    @State private var folder: URL?
    @State private var picking = false
    @State private var busy = false
    @State private var status = ""
    @State private var filter = Filter.all

    var visible: [Album] { albums.filter { filter == .all || (filter == .mine) == $0.isUser } }
    var allSelected: Bool { !visible.isEmpty && visible.allSatisfy { selected.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section("1. Select albums (\(selected.count) selected)") {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected { visible.forEach { selected.remove($0.id) } }
                        else { visible.forEach { selected.insert($0.id) } }
                    }
                    ForEach(visible) { a in
                        Button {
                            if !selected.insert(a.id).inserted { selected.remove(a.id) }
                        } label: {
                            HStack {
                                Text(a.title)
                                Spacer()
                                if selected.contains(a.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("2. Destination folder") {
                    Button(folder?.lastPathComponent ?? "Choose folder in Files") { picking = true }
                }
                Section {
                    Button("Sync") { Task { await sync() } }
                        .disabled(busy || folder == nil || selected.isEmpty)
                    if !status.isEmpty { Text(status).font(.footnote) }
                }
            }
            .navigationTitle("Photo Sync")
        }
        .task { await loadAlbums() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) {
            if case .success(let url) = $0 { folder = url }
        }
    }

    func loadAlbums() async {
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) != .denied else {
            status = "Allow Photos access in Settings."; return
        }
        var list: [Album] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
                .enumerateObjects { c, _, _ in
                    if PHAsset.fetchAssets(in: c, options: nil).count > 0 {
                        list.append(Album(id: c.localIdentifier, title: c.localizedTitle ?? "Album", isUser: type == .album, collection: c))
                    }
                }
        }
        albums = list
    }

    func sync() async {
        guard let root = folder, root.startAccessingSecurityScopedResource() else {
            status = "Cannot access folder."; return
        }
        defer { root.stopAccessingSecurityScopedResource() }
        busy = true; defer { busy = false }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true          // download from iCloud if needed
        var copied = 0, skipped = 0

        for a in albums where selected.contains(a.id) {
            let dir = root.appendingPathComponent(a.title.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let assets = PHAsset.fetchAssets(in: a.collection, options: nil)

            for i in 0..<assets.count {
                for r in PHAssetResource.assetResources(for: assets[i]) where r.type == .photo {
                    let dest = dir.appendingPathComponent(r.originalFilename)
                    if FileManager.default.fileExists(atPath: dest.path) { skipped += 1; continue }
                    do {
                        try await PHAssetResourceManager.default().writeData(for: r, toFile: dest, options: opts)
                        copied += 1
                    } catch { }
                    status = "\(a.title): copied \(copied), skipped \(skipped)…"
                }
            }
        }
        status = "Done ✅  Copied \(copied), skipped \(skipped) existing."
    }
}
