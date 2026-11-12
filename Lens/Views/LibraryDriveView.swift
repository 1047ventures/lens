import SwiftUI

/// Everything on one drive (or the Mac, or the Photos app), folder by folder, biggest first.
/// Works from Lens's memory of the drive, so it opens instantly even when the drive is unplugged.
struct LibraryDriveView: View {
    let driveID: String

    @ObservedObject private var catalog = DriveCatalog.shared
    @State private var folders: [DriveFolder] = []
    @State private var loading = true
    @State private var show: Show = .all
    @State private var order: Order = .size

    enum Show: String, CaseIterable { case all = "Everything", video = "Video", photo = "Photos" }
    enum Order: String, CaseIterable { case size = "Biggest", newest = "Newest", name = "A to Z" }

    private var drive: CatalogDrive? { catalog.drives.first { $0.id == driveID } }

    private var shown: [DriveFolder] {
        let filtered = folders.filter {
            switch show {
            case .all: return true
            case .video: return $0.videos > 0
            case .photo: return $0.photos > 0
            }
        }
        switch order {
        case .size: return filtered.sorted { bytes($0) > bytes($1) }
        case .newest: return filtered.sorted { $0.newest > $1.newest }
        case .name: return filtered.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    private func bytes(_ f: DriveFolder) -> Int64 {
        switch show {
        case .all: return f.videoBytes + f.photoBytes
        case .video: return f.videoBytes
        case .photo: return f.photoBytes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if loading {
                ProgressView().padding(40)
                Spacer()
            } else if shown.isEmpty {
                Text(folders.isEmpty ? "Lens hasn't read this drive yet." : "Nothing here matches.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { folder in
                            NavigationLink(value: FootageRoute.folder(driveID: driveID, path: folder.path)) { row(folder) }
                                .buttonStyle(.plain)
                            Divider().overlay(Theme.line)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .background(Theme.ground)
        .task(id: driveID) {
            guard let drive else { loading = false; return }
            folders = await Task.detached(priority: .userInitiated) { DriveCatalog.folders(on: drive) }.value
            loading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let drive, !drive.isMac, !drive.isPhotos {
                        TextField("Name", text: Binding(get: { drive.name }, set: { catalog.rename(drive.id, to: $0) }))
                            .textFieldStyle(.plain).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    } else {
                        Text(drive?.name ?? "Drive").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    }
                    Text(summary).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("", selection: $show) { ForEach(Show.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Picker("", selection: $order) { ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                Text("\(shown.count) folder\(shown.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var summary: String {
        guard let drive else { return "" }
        var parts: [String] = []
        if drive.videoCount > 0 { parts.append("\(drive.videoCount.formatted()) videos, \(ByteFormat.string(drive.videoBytes))") }
        if drive.photoCount > 0 { parts.append("\(drive.photoCount.formatted()) photos, \(ByteFormat.string(drive.photoBytes))") }
        if !drive.isPhotos && !drive.isMac && !catalog.isPlugged(drive) { parts.append("in the drawer") }
        return parts.joined(separator: " · ")
    }

    private func row(_ folder: DriveFolder) -> some View {
        let total = bytes(folder)
        let biggest = max(folders.map(bytes).max() ?? 1, 1)
        return HStack(spacing: 14) {
            Image(systemName: folder.videos > 0 ? "film.stack" : "photo.stack")
                .font(.system(size: 16)).foregroundStyle(Theme.text3).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(folder.parent.isEmpty ? " " : folder.parent)
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 220, alignment: .leading)
            // How big this folder is next to the biggest one, at a glance.
            GeometryReader { geo in
                Capsule().fill(Theme.tealDim).frame(width: max(3, geo.size.width * CGFloat(Double(total) / Double(biggest))))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormat.string(total)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text2)
                Text(counts(folder)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .frame(width: 150, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func counts(_ f: DriveFolder) -> String {
        var parts: [String] = []
        if f.videos > 0 { parts.append("\(f.videos) video\(f.videos == 1 ? "" : "s")") }
        if f.photos > 0 { parts.append("\(f.photos) photo\(f.photos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ") + " · " + f.newest.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// One folder's photo and video totals, from Lens's memory of a drive.
struct DriveFolder: Identifiable {
    let path: String
    var videos = 0, photos = 0
    var videoBytes: Int64 = 0, photoBytes: Int64 = 0
    var newest = Date.distantPast
    var id: String { path }
    var name: String { path.isEmpty ? "Top of the drive" : (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}
