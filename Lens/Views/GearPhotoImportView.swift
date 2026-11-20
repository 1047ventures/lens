import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Add from photo": the user picks photos, Claude guesses what each one is, she fixes anything and
/// ticks what to add. Nothing reaches Gear until she taps Add.
struct GearPhotoImportView: View {
    @EnvironmentObject private var money: MoneyStore
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id = UUID()
        var jpeg: Data
        var image: NSImage?
        var loading = true
        var error: String?
        var include = true
        var name = ""
        var kind: GearItem.Kind = .other
        var serial = ""
        var value: Double?
        var sure = true
    }

    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add gear from photos").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            if !GearIdentifier.hasKey {
                Text("Lens needs your Claude key to recognise gear. Add it in Log-ins, then come back.")
                    .font(.system(size: 13)).foregroundStyle(Theme.amber)
            } else if rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick one or more photos of your gear. Lens works out the brand, model and type, and a rough used price. You check everything before anything is added.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Button("Choose photos") { choose() }.buttonStyle(PrimaryButtonStyle())
                    Text("Photos on your iPhone: in the chooser, use the Import from iPhone option in the bottom left of the window or the File menu, then pick the photo.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .panel()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($rows) { $row in card($row) }
                    }
                }
            }
            HStack {
                if !rows.isEmpty {
                    Button("Choose more photos") { choose() }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button(addLabel) { addSelected() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(ready.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640, height: 600)
        .background(Theme.ground)
    }

    private var ready: [Row] {
        rows.filter { $0.include && !$0.loading && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var addLabel: String { ready.isEmpty ? "Add to Gear" : "Add \(ready.count) to Gear" }

    private func card(_ row: Binding<Row>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: row.include).labelsHidden().toggleStyle(.checkbox)
            Group {
                if let img = row.wrappedValue.image {
                    Image(nsImage: img).resizable().scaledToFill()
                } else { Rectangle().fill(Theme.raised) }
            }
            .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
            if row.wrappedValue.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at this photo...").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let e = row.wrappedValue.error {
                        Text(e).font(.system(size: 12)).foregroundStyle(Theme.amber)
                    } else if !row.wrappedValue.sure {
                        Text("Lens isn't sure about this one. Please check the name.").font(.system(size: 12)).foregroundStyle(Theme.amber)
                    }
                    TextField("Name", text: row.name, prompt: Text("Brand and model, like Sony A7S III"))
                    HStack {
                        Picker("Type", selection: row.kind) { ForEach(GearItem.Kind.allCases) { Text($0.label).tag($0) } }
                        TextField("Serial", text: row.serial, prompt: Text("Serial number (optional)"))
                    }
                    HStack {
                        TextField("Used value", value: row.value, format: .currency(code: "USD").precision(.fractionLength(0)), prompt: Text("Rough price"))
                        Text("A rough guess, not a receipt").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
        }
        .panel(padding: 12)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose photos of your gear"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let jpeg = GearIdentifier.jpeg(from: url) else { continue }
            let row = Row(jpeg: jpeg, image: NSImage(data: jpeg))
            rows.append(row)
            let id = row.id
            Task {
                do {
                    let g = try await GearIdentifier.identify(jpeg: jpeg)
                    update(id) {
                        $0.name = [g.brand, g.model].filter { !$0.isEmpty }.joined(separator: " ")
                        $0.kind = g.kind; $0.serial = g.serial; $0.value = g.usedValue; $0.sure = g.sure
                        $0.loading = false
                    }
                } catch {
                    update(id) { $0.error = error.localizedDescription; $0.sure = false; $0.loading = false }
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Row) -> Void) {
        if let i = rows.firstIndex(where: { $0.id == id }) { change(&rows[i]) }
    }

    private func addSelected() {
        for r in ready {
            var item = GearItem(name: r.name.trimmingCharacters(in: .whitespaces), kind: r.kind, bought: Date(), paid: r.value ?? 0, lifeYears: 5)
            item.serial = r.serial.isEmpty ? nil : r.serial
            item.photoFile = GearIdentifier.keepPhoto(r.jpeg)
            item.paidIsEstimate = r.value != nil ? true : nil
            money.saveGear(item)
        }
        dismiss()
    }
}
