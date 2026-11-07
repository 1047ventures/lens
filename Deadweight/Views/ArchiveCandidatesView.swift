import SwiftUI

struct ArchiveCandidatesView: View {
    @ObservedObject var viewModel: ScanViewModel

    private var totalBytes: Int64 { viewModel.archiveCandidates.reduce(0) { $0 + $1.file.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ready to Retire")
                    .font(.title2.bold())
                Spacer()
                if !viewModel.archiveCandidates.isEmpty {
                    Button("Send Them Off") {
                        try? viewModel.applyArchive(viewModel.archiveCandidates, enforceCheckpoint: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.trustSettings.archiveDestinationPath == nil)
                }
            }
            .padding([.top, .horizontal], 24)
            .padding(.bottom, 4)

            Text("Footage nobody's touched in a while, and that isn't part of any live Premiere project. Not deleted — just relocated off this drive to somewhere cheaper, like an external HDD.")
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            if viewModel.trustSettings.archiveDestinationPath == nil {
                Text("Set an Archive destination folder in Settings before moving files here.")
                    .foregroundColor(.orange)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            } else {
                Text("\(ByteFormat.string(totalBytes)) total — will move to \(viewModel.trustSettings.archiveDestinationPath!).")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            if viewModel.archiveCandidates.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundColor(.green)
                    Text("Nothing's collecting dust yet.").foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.archiveCandidates) { candidate in
                        HStack(alignment: .top, spacing: 10) {
                            ThumbnailImageView(file: candidate.file, fallbackSystemImage: "archivebox")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.file.filename).fontWeight(.medium)
                                if let caption = candidate.file.metadataCaption {
                                    Text(caption)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(candidate.reason)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(ByteFormat.string(candidate.file.sizeBytes)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
