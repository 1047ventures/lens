import SwiftUI

struct OrganizeView: View {
    @ObservedObject var viewModel: ScanViewModel
    @State private var scopeRoot: URL?

    private var currentRule: OrganizeRule {
        guard let scopeRoot else { return viewModel.organizeSettings.defaultRule }
        return viewModel.organizeSettings.rule(for: scopeRoot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Round Up the Strays")
                    .font(.title2.bold())
                Spacer()
                if !viewModel.organizeProposals.isEmpty {
                    Button("File It All Away") {
                        try? viewModel.applyOrganize(viewModel.organizeProposals, enforceCheckpoint: false)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding([.top, .horizontal], 24)
            .padding(.bottom, 4)

            Text("Pick what matters, and in what order — footage gets nested into folders by whichever factors you turn on.")
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            ruleBuilder
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Divider()

            if viewModel.organizeProposals.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundColor(.green)
                    Text("Nothing loose left to wrangle.").foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.organizeProposals) { proposal in
                        HStack(alignment: .top, spacing: 10) {
                            ThumbnailImageView(file: proposal.file, fallbackSystemImage: "film")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proposal.file.filename).fontWeight(.medium)
                                if let caption = proposal.file.metadataCaption {
                                    Text(caption)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(proposal.file.path)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Text("→ " + proposal.proposedPath)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var ruleBuilder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Applies to", selection: $scopeRoot) {
                Text("Default — every folder without its own rule").tag(URL?.none)
                ForEach(viewModel.roots, id: \.self) { root in
                    Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent).tag(URL?.some(root))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)

            if let scopeRoot, viewModel.organizeSettings.hasOverride(for: scopeRoot) {
                Button("Use Default Instead") {
                    viewModel.organizeSettings.clearOverride(for: scopeRoot)
                    viewModel.recomputeOrganizeProposals()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack(spacing: 8) {
                ForEach(OrganizeFactor.allCases) { factor in
                    factorChip(factor)
                }
            }

            if currentRule.factors.isEmpty {
                Text("Pick at least one factor above to build a folder structure.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("Organized/" + currentRule.factors.map { "⟨\($0.label)⟩" }.joined(separator: "/") + "/filename")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func factorChip(_ factor: OrganizeFactor) -> some View {
        let position = currentRule.position(of: factor)
        return Button {
            var rule = currentRule
            rule.toggle(factor)
            viewModel.organizeSettings.setRule(rule, for: scopeRoot)
            viewModel.recomputeOrganizeProposals()
        } label: {
            HStack(spacing: 5) {
                if let position {
                    Text("\(position)")
                        .font(.caption2.bold())
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.3)))
                }
                Text(factor.label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(position != nil ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundColor(position != nil ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
