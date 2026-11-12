import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing

/// One folder from Library search, opened inside Lens: a thumbnail of every photo and video,
/// a full preview (videos play, RAW photos show), and files she can drag straight into
/// Premiere, Lightroom or an email.
struct LibraryFolderView: View {
    let driveID: String
    let folder: String

    @ObservedObject private var catalog = DriveCatalog.shared
    @State private var items: [FolderItem] = []
    @State private var selected: FolderItem.ID?
    @State private var previewing: FolderItem?

    private var drive: CatalogDrive? { catalog.drives.first { $0.id == driveID } }
    private var folderURL: URL? { drive.flatMap { catalog.location(of: folder, on: $0) } }
    private var title: String { folder.isEmpty ? (drive?.name ?? "Drive") : (folder as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if items.isEmpty {
                Text("No photos or videos in this folder.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(items) { item in tile(item) }
                    }
                    .padding(24)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard let item = items.first(where: { $0.id == selected }), item.url != nil else { return .ignored }
                    previewing = item
                    return .handled
                }
            }
        }
        .background(Theme.ground)
        .task(id: "\(driveID)|\(folder)|\(folderURL != nil)") { load() }
        .sheet(item: $previewing) { item in
            PreviewSheet(items: items.filter { $0.url != nil }, start: item)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if folderURL != nil {
                Text("Drag any file into Premiere, Lightroom or an email")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                if let item = items.first(where: { $0.id == selected }), item.url != nil {
                    Button("Preview") { previewing = item }.buttonStyle(SecondaryButtonStyle())
                    Button("Open") { if let url = item.url { NSWorkspace.shared.open(url) } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else if let drive {
                Label("Plug in \(drive.name) to see and open these", systemImage: "externaldrive")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var subtitle: String {
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        let photos = items.filter { $0.kind == .photo }.count, videos = items.filter { $0.kind == .video }.count
        var parts: [String] = []
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        parts.append(ByteFormat.string(bytes))
        parts.append(drive?.name ?? "")
        return parts.joined(separator: " · ")
    }

    private func tile(_ item: FolderItem) -> some View {
        let isSelected = selected == item.id
        return VStack(alignment: .leading, spacing: 6) {
            Thumbnail(url: item.url, kind: item.kind)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "play.fill").font(.system(size: 10)).padding(5)
                            .background(.black.opacity(0.55)).clipShape(Circle()).padding(6).foregroundStyle(.white)
                    }
                }
            Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Text("\(ByteFormat.string(item.size)) · \(item.modified.formatted(.dateTime.month().day().year()))")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(8)
        .background(isSelected ? Theme.teal.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Theme.teal.opacity(0.7) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.url != nil { previewing = item } }
        .simultaneousGesture(TapGesture().onEnded { selected = item.id })
        .onDrag { item.url.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() } ?? NSItemProvider() }
        .contextMenu {
            if let url = item.url {
                Button("Preview") { previewing = item }
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func load() {
        if let url = folderURL {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let found = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            items = found.compactMap { file in
                guard let kind = CatalogKind.of(file.pathExtension.lowercased()), kind != .project else { return nil }
                let v = try? file.resourceValues(forKeys: Set(keys))
                return FolderItem(name: file.lastPathComponent, size: Int64(v?.fileSize ?? 0),
                                  modified: v?.contentModificationDate ?? Date(), kind: kind, url: file)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else if let drive {
            items = DriveCatalog.files(in: folder, on: drive)
        }
    }
}

struct FolderItem: Identifiable, Hashable {
    let name: String
    let size: Int64
    let modified: Date
    let kind: CatalogKind
    /// Where it is right now; nil when its drive is unplugged.
    let url: URL?
    var id: String { name }
}

// MARK: - Thumbnails

/// A small picture of any photo (RAW included) or video, made by macOS on demand and dropped
/// when it scrolls away, so a folder of thousands stays light.
private struct Thumbnail: View {
    let url: URL?
    let kind: CatalogKind
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: kind == .video ? "film" : "photo").font(.system(size: 24)).foregroundStyle(Theme.muted)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 140),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}

// MARK: - Full preview

private struct PreviewSheet: View {
    let items: [FolderItem]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    init(items: [FolderItem], start: FolderItem) {
        self.items = items
        _index = State(initialValue: items.firstIndex(of: start) ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(index == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Button { index = min(items.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(index >= items.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                Text(items.indices.contains(index) ? items[index].name : "")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(index + 1) of \(items.count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                if items.indices.contains(index), let url = items[index].url {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Theme.panel)
            if items.indices.contains(index), let url = items[index].url {
                QuickLookView(url: url)
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 760)
        .background(Theme.ground)
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
