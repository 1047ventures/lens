import SwiftUI

struct DuplicatesView: View {
    @ObservedObject var viewModel: ScanViewModel

    private var totalWasted: Int64 { viewModel.duplicateGroups.reduce(0) { $0 + $1.wastedBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Duplicate Weight")
                    .font(.title2.bold())
                Spacer()
                if !viewModel.duplicateGroups.isEmpty {
                    Text("Could free \(ByteFormat.string(totalWasted))")
                        .foregroundColor(.secondary)
                    Button("Cut All Extras") {
                        try? viewModel.applyDuplicateRemoval(viewModel.duplicateGroups, enforceCheckpoint: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding([.top, .horizontal], 24)
            .padding(.bottom, 12)

            if viewModel.duplicateGroups.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.duplicateGroups) { group in
                        DuplicateGroupRow(group: group, viewModel: viewModel)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundColor(.green)
            Text("No dead weight here — you're clean.").foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @ObservedObject var viewModel: ScanViewModel

    private var representativeFile: MediaFile {
        group.files.first(where: { $0.path == group.keepPath }) ?? group.files[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ThumbnailImageView(file: representativeFile, fallbackSystemImage: "square.on.square")
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(group.files.count) identical copies")
                            .fontWeight(.medium)
                        Spacer()
                        Text(ByteFormat.string(group.wastedBytes) + " wasted")
                            .foregroundColor(.secondary)
                        Button("Cut Extras") {
                            try? viewModel.applyDuplicateRemoval([group], enforceCheckpoint: false)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let caption = representativeFile.metadataCaption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            ForEach(group.files, id: \.path) { file in
                HStack {
                    Image(systemName: file.path == group.keepPath ? "checkmark.circle.fill" : "trash")
                        .foregroundColor(file.path == group.keepPath ? .green : .red)
                    Text(file.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.isLinked {
                        Text("linked: \(file.linkedProjects.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
