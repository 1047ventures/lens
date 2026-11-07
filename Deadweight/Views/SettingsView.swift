import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: ScanViewModel

    var body: some View {
        Form {
            Section("Trust level — \"I trust you\"") {
                Text("Off (default): every batch is shown for review before anything moves. On: Deadweight applies that action type automatically on future scans, but a batch above your checkpoint below still pauses for confirmation, and every action stays undoable.")
                    .foregroundColor(.secondary)
                    .font(.caption)

                ForEach(ActionType.allCases) { type in
                    Toggle(isOn: Binding(
                        get: { viewModel.trustSettings.isAutoApply(type) },
                        set: { viewModel.trustSettings.setAutoApply(type, $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(type.rawValue).fontWeight(.medium)
                            Text(type.description).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("Auto-apply checkpoint") {
                Text("An auto-apply batch bigger than either limit below pauses for a one-time confirmation instead of running unattended.")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Stepper("Max files per batch: \(viewModel.trustSettings.checkpointFileCount)",
                        value: $viewModel.trustSettings.checkpointFileCount, in: 10...5000, step: 10)
                    .onChange(of: viewModel.trustSettings.checkpointFileCount) { _, _ in viewModel.trustSettings.save() }
                Stepper("Max GB per batch: \(Int(viewModel.trustSettings.checkpointGigabytes))",
                        value: $viewModel.trustSettings.checkpointGigabytes, in: 1...2000, step: 5)
                    .onChange(of: viewModel.trustSettings.checkpointGigabytes) { _, _ in viewModel.trustSettings.save() }
            }

            Section("Stale footage") {
                Stepper("Flag footage untouched for \(viewModel.trustSettings.staleAfterDays) days",
                        value: $viewModel.trustSettings.staleAfterDays, in: 30...730, step: 30)
                    .onChange(of: viewModel.trustSettings.staleAfterDays) { _, _ in viewModel.trustSettings.save() }
            }

            Section("Archive destination") {
                HStack {
                    Text(viewModel.trustSettings.archiveDestinationPath ?? "Not set")
                        .foregroundColor(viewModel.trustSettings.archiveDestinationPath == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { pickArchiveDestination() }
                }
            }

            Section("Undo (Second Thoughts)") {
                if viewModel.recentBatches.isEmpty {
                    Text("No actions taken yet.").foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.recentBatches) { batch in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(batch.label) — \(batch.entries.count) file(s)")
                                Text(batch.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(ByteFormat.string(batch.totalBytes)).foregroundColor(.secondary)
                            Button("Undo") { viewModel.undo(batch) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pickArchiveDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Set as Archive"
        if panel.runModal() == .OK, let url = panel.urls.first {
            viewModel.trustSettings.archiveDestinationPath = url.path
            viewModel.trustSettings.save()
        }
    }
}
