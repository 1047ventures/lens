import SwiftUI
import AppKit

/// Shows exactly what the Library's "Get space back" suggestions would clear: every file or
/// folder, which drive it is on, how big it is and why. It only explains. Nothing is moved or
/// deleted from here.
struct CleanupExplainedView: View {
    @ObservedObject var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @ObservedObject private var catalog = DriveCatalog.shared

    private struct Line: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let drive: String
        let bytes: Int64
        let why: String
    }

    private struct Bundle: Identifiable {
        let id: String
        let title: String
        let blurb: String
        let lines: [Line]
        var bytes: Int64 { lines.reduce(0) { $0 + $1.bytes } }
    }

    private static let showLimit = 40

    var body: some View {
        let all = bundles
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(all)
                if all.isEmpty {
                    Text("Nothing to clean up right now.")
                        .font(Theme.font(size: 14)).foregroundStyle(Theme.text3).panel(padding: 22)
                } else {
                    ForEach(all) { bundle in bundlePanel(bundle) }
                }
            }
            .padding(.horizontal, 48).padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.ground)
    }

    private func header(_ all: [Bundle]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What Lens would clean up")
                    .font(Theme.font(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                Text("This is the full list behind the suggestions. Nothing is moved or deleted from this page.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !all.isEmpty {
                Button("Ask Lens about this list") { ask(overallQuestion(all)) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func bundlePanel(_ bundle: Bundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(bundle.title).font(Theme.font(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(bundle.lines.count) item\(bundle.lines.count == 1 ? "" : "s") · \(ByteFormat.string(bundle.bytes))")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Ask Lens about this") { ask(bundleQuestion(bundle)) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text(bundle.blurb).font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                let shown = Array(bundle.lines.sorted { $0.bytes > $1.bytes }.prefix(Self.showLimit))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Divider().overlay(Theme.lineSoft) }
                    lineRow(line)
                }
                if bundle.lines.count > Self.showLimit {
                    Divider().overlay(Theme.lineSoft)
                    Text("and \(bundle.lines.count - Self.showLimit) more, smaller ones")
                        .font(Theme.font(size: 12)).foregroundStyle(Theme.muted).padding(12)
                }
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }

    private func lineRow(_ line: Line) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.name).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("On \(line.drive) · \(line.why)")
                    .font(Theme.font(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Text(line.path).font(Theme.font(size: 11)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(line.bytes)).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Button("What is this?") {
                ask("What is \"\(line.name)\" on \(line.drive) (\(ByteFormat.string(line.bytes)))? Lens suggests cleaning it up because: \(line.why). Is it safe to remove?")
            }
            .buttonStyle(.link).font(Theme.font(size: 12))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func ask(_ question: String) {
        navigator.askDraft = question
        navigator.askOpen = true
    }

    private func overallQuestion(_ all: [Bundle]) -> String {
        let parts = all.map { "\($0.title) (\($0.lines.count) items, \(ByteFormat.string($0.bytes)))" }
        return "Lens suggests cleaning up: \(parts.joined(separator: "; ")). What is the biggest thing here, and is it safe to remove?"
    }

    private func bundleQuestion(_ b: Bundle) -> String {
        "Lens suggests cleaning up \(b.lines.count) items in \"\(b.title)\" (\(ByteFormat.string(b.bytes)) in all). \(b.blurb) Is it safe to remove them?"
    }

    // MARK: Building the list

    private var bundles: [Bundle] {
        var result: [Bundle] = []

        var cacheByKind: [CacheKind: [Line]] = [:]
        for item in viewModel.cacheItems {
            cacheByKind[item.kind, default: []].append(
                Line(name: item.name, path: item.path, drive: driveName(item.path), bytes: item.sizeBytes,
                     why: "Premiere rebuilds this on its own"))
        }
        let kindOrder: [CacheKind] = [.mediaCacheFolder, .previewFilesFolder, .conformedAudioFolder, .peakFile]
        for kind in kindOrder {
            guard let lines = cacheByKind[kind], !lines.isEmpty else { continue }
            result.append(Bundle(id: "cache-\(kind.rawValue)", title: "Premiere cache: \(kind.rawValue.lowercased())",
                                 blurb: "Premiere makes these files by itself to play things back faster. It rebuilds them whenever it needs them.",
                                 lines: lines))
        }

        var dupeLines: [Line] = []
        for group in viewModel.duplicateGroups {
            let keepName = (group.keepPath as NSString).lastPathComponent
            let keepDrive = driveName(group.keepPath)
            let keepIsLinked = group.files.first { $0.path == group.keepPath }?.isLinked ?? false
            for file in group.filesToRemove {
                let why = "exact copy of \(keepName) on \(keepDrive)" + (keepIsLinked ? ", the one Premiere uses" : "")
                dupeLines.append(Line(name: (file.path as NSString).lastPathComponent, path: file.path,
                                      drive: driveName(file.path), bytes: file.sizeBytes, why: why))
            }
        }
        if !dupeLines.isEmpty {
            result.append(Bundle(id: "dupes", title: "Exact copies",
                                 blurb: "Each of these is identical to another file that stays put. The copy Premiere uses is always the one kept.",
                                 lines: dupeLines))
        }

        let old = viewModel.archiveCandidates.map {
            Line(name: ($0.file.path as NSString).lastPathComponent, path: $0.file.path,
                 drive: driveName($0.file.path), bytes: $0.file.sizeBytes, why: $0.reason.lowercasedFirst)
        }
        if !old.isEmpty {
            result.append(Bundle(id: "old", title: "Untouched footage",
                                 blurb: "Not used for a long while and not in any Premiere project. These would be archived, not thrown away.",
                                 lines: old))
        }
        return result
    }

    private func driveName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1, parts[0] == "Volumes" else { return "This Mac" }
        let vol = parts[1]
        return catalog.drives.first { $0.name == vol }?.name ?? vol
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
