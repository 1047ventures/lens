import SwiftUI
import AppKit

/// The top of Library: every drive Emma owns (plugged in or in a drawer) and one search box
/// across all of them.
struct LibraryDrivesView: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @ObservedObject private var catalog = DriveCatalog.shared
    @State private var query = ""
    @State private var hits: [CatalogHit] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let url = catalog.newDrive { newDriveBanner(url) }
            searchBox
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { results }
            drivesGrid
        }
    }

    // MARK: New drive

    private func newDriveBanner(_ url: URL) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 22)).foregroundStyle(Theme.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(url.lastPathComponent) is plugged in").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Add it and Lens will read what's on it. Nothing gets moved or deleted.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Not now") { catalog.dismissNewDrive() }.buttonStyle(SecondaryButtonStyle())
            Button("Add it") {
                viewModel.addRoot(url)
                catalog.dismissNewDrive()
                viewModel.scan()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .panel(padding: 16)
        .accentBar(Theme.teal)
    }

    // MARK: Search

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Find a shoot, client or file on any drive", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
            if searching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .onChange(of: query) { _, text in runSearch(text) }
    }

    private func runSearch(_ text: String) {
        searchTask?.cancel()
        let drives = catalog.drives
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { DriveCatalog.search(text, drives: drives) }.value
            guard !Task.isCancelled else { return }
            hits = found
            searching = false
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty && !searching {
                Text(catalog.drives.isEmpty ? "Add a drive first, then everything on it is searchable."
                                            : "Nothing on any drive matches that.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(14)
            }
            ForEach(hits) { hit in
                resultRow(hit)
                if hit.id != hits.last?.id { Divider().overlay(Theme.line) }
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func resultRow(_ hit: CatalogHit) -> some View {
        let drive = catalog.drives.first { $0.id == hit.driveID }
        let folderName = hit.folder.isEmpty ? (drive?.name ?? "") : (hit.folder as NSString).lastPathComponent
        return NavigationLink(value: FootageRoute.folder(driveID: hit.driveID, path: hit.folder)) {
            resultLabel(hit, drive: drive, folderName: folderName)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let drive, let url = catalog.location(of: hit.folder, on: drive) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func resultLabel(_ hit: CatalogHit, drive: CatalogDrive?, folderName: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.text3)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(hit.files) file\(hit.files == 1 ? "" : "s") · \(ByteFormat.string(hit.bytes)) · \(hit.folder.isEmpty ? hit.sample : hit.folder)")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let drive {
                if drive.isPhotos || catalog.location(of: hit.folder, on: drive) != nil {
                    Text(drive.name).font(.system(size: 12)).foregroundStyle(Theme.text3)
                } else {
                    Label("\(drive.name) · in the drawer", systemImage: "externaldrive")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: Drives

    private var drivesGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your drives")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                macTile
                photosTile
                ForEach(catalog.outside) { drive in tile(drive) }
            }
        }
    }

    @ViewBuilder
    private var macTile: some View {
        if let mac = catalog.mac {
            tile(mac)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("This Mac", systemImage: "laptopcomputer").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("See how many photos and videos are sitting on your Mac's own drive.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button(catalog.macScanning ? "Looking…" : "Look") { catalog.scanMac() }
                    .buttonStyle(SecondaryButtonStyle()).disabled(catalog.macScanning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    @ViewBuilder
    private var photosTile: some View {
        if let photos = catalog.photos {
            tile(photos)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Photos app", systemImage: "photo.on.rectangle").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(catalog.photosRefused
                     ? "Lens isn't allowed into Photos. Turn it on in System Settings, Privacy and Security, Photos."
                     : "See and search every photo and video in your Photos app. Lens only looks; it never changes anything there.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if catalog.photosRefused {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(catalog.photosReading ? "Looking…" : "Look in Photos") { catalog.readPhotos() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(catalog.photosReading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    private func tile(_ drive: CatalogDrive) -> some View {
        let plugged = catalog.isPlugged(drive)
        let full = drive.fractionUsed
        let barColor = full > 0.85 ? Theme.coral : full > 0.7 ? Theme.amber : (plugged ? Theme.teal : Theme.muted)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: drive.isMac ? "laptopcomputer" : drive.isPhotos ? "photo.on.rectangle" : plugged ? "externaldrive.fill" : "externaldrive")
                    .foregroundStyle(plugged ? Theme.text : Theme.muted)
                TextField("Name", text: Binding(get: { drive.name }, set: { catalog.rename(drive.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(barColor).frame(width: geo.size.width * full)
                }
            }
            .frame(height: 5)
            .opacity(drive.isPhotos ? 0 : 1)
            Text(drive.isPhotos ? "\(ByteFormat.string(drive.photoBytes + drive.videoBytes)) in all"
                                : "\(Int((full * 100).rounded()))% full · \(ByteFormat.string(drive.free)) free")
                .font(.system(size: 12)).foregroundStyle(!drive.isPhotos && full > 0.85 ? Theme.coral : Theme.text3)
            Text(contents(drive)).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Text(status(drive, plugged: plugged)).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .opacity(plugged ? 1 : 0.8)
        .contextMenu {
            if drive.isMac {
                Button("Look again") { catalog.scanMac() }
            } else if drive.isPhotos {
                Button("Look again") { catalog.readPhotos() }
            } else if plugged, let url = catalog.mounted[drive.id] {
                Button("Read it again") {
                    if !viewModel.roots.contains(url) { viewModel.addRoot(url) }
                    viewModel.scan()
                }
            }
            Button("Forget this drive", role: .destructive) { catalog.forget(drive.id) }
        }
    }

    private func contents(_ drive: CatalogDrive) -> String {
        guard drive.lastScanned != nil else { return "Not read yet" }
        var parts: [String] = []
        if drive.isPhotos {
            if drive.photoCount > 0 { parts.append("\(drive.photoCount.formatted()) photos") }
            if drive.videoCount > 0 { parts.append("\(drive.videoCount.formatted()) videos") }
            return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
        }
        if drive.videoCount > 0 { parts.append("\(ByteFormat.string(drive.videoBytes)) video") }
        if drive.photoCount > 0 { parts.append("\(drive.photoCount.formatted()) photos") }
        return parts.isEmpty ? "No photos or video" : parts.joined(separator: " · ")
    }

    private func status(_ drive: CatalogDrive, plugged: Bool) -> String {
        if drive.isMac {
            return catalog.macScanning ? "Looking…" : "Desktop, Downloads, Documents, Movies, Pictures"
        }
        if drive.isPhotos { return catalog.photosReading ? "Looking…" : "Searchable by year and month" }
        if plugged { return "Plugged in" }
        return "In the drawer · last seen \(drive.lastSeen.formatted(.dateTime.month().day()))"
    }
}
