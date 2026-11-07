import SwiftUI

struct CacheCleanupView: View {
    @ObservedObject var viewModel: ScanViewModel

    private var totalBytes: Int64 { viewModel.cacheItems.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Premiere's Dead Weight")
                    .font(.title2.bold())
                Spacer()
                if !viewModel.cacheItems.isEmpty {
                    Button("Cut \(ByteFormat.string(totalBytes)) loose") {
                        try? viewModel.applyCacheCleanup(viewModel.cacheItems, enforceCheckpoint: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding([.top, .horizontal], 24)
            .padding(.bottom, 4)

            Text("Media cache and preview files are regenerated automatically by Premiere the next time it needs them — deleting them is always safe.")
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            if viewModel.cacheItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundColor(.green)
                    Text("Premiere's not hoarding anything right now.").foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.cacheItems) { item in
                        HStack {
                            Image(systemName: "trash.circle").foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text(item.name).fontWeight(.medium)
                                Text(item.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.sizeBytes)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
