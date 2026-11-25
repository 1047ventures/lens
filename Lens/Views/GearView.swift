import SwiftUI

/// Everything the user owns, what it's worth today (feeds "What's it all worth?" in Money),
/// and when it was last looked after.
struct GearView: View {
    @EnvironmentObject private var money: MoneyStore
    @State private var editing: GearItem?
    @EnvironmentObject private var appearance: Appearance
    @State private var fromPhoto = false

    var body: some View {
        if appearance.simple { simpleBody } else { fullBody }
    }

    // MARK: Simple

    private var simpleBody: some View {
        let items = money.gear.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let worth = items.reduce(0) { $0 + $1.value() }
        let kinds = GearItem.Kind.allCases.filter { k in items.contains { $0.kind == k } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gear").font(Theme.display(size: 34)).foregroundStyle(Theme.text)
                        Text(items.isEmpty ? "The cameras, lenses and drives you work with."
                             : "Your kit is worth about \(Money.string(worth)).")
                            .font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Add from photo") { fromPhoto = true }.buttonStyle(SecondaryButtonStyle())
                    Button("Add gear") {
                        editing = GearItem(name: "", kind: .camera, bought: Date(), paid: 0, lifeYears: 5)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No gear yet").font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                        Text("Add your cameras, lenses and drives, or snap a photo and Lens will fill in the details.")
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                    }
                    .panel(padding: 22)
                }
                ArrangeablePage("gear", spacing: 28, boxes: kinds.map { kind in
                    PageBox("kind-" + kind.rawValue, kind.label, color: Palette.gold) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(kind.label).font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                                ForEach(items.filter { $0.kind == kind }) { simpleCard($0) }
                            }
                        }
                    }
                })
            }
            .padding(40)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { item in GearEditor(item: item) }
        .sheet(isPresented: $fromPhoto) { GearPhotoImportView() }
    }

    private func simpleCard(_ item: GearItem) -> some View {
        var line = "Bought " + item.bought.formatted(.dateTime.month(.abbreviated).year())
        if item.paid > 0 { line += " · " + (item.paidIsEstimate == true ? "about " : "") + Money.string(item.paid) }
        return Button { editing = item } label: {
            HStack(alignment: .top, spacing: 12) {
                if let f = item.photoFile, let img = NSImage(contentsOf: GearIdentifier.photoURL(f)) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: item.kind.icon).font(Theme.font(size: 18)).foregroundStyle(Theme.text2).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name.isEmpty ? "Untitled" : item.name).font(Theme.display(size: 17)).foregroundStyle(Theme.text).lineLimit(2)
                    Text(line).font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                    if item.needsService {
                        Text("Due for a check-up").font(Theme.font(size: 12)).foregroundStyle(Theme.amber)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    /// Everything's boxes in their usual order; she can rearrange or hide them.
    private func fullBoxes(items: [GearItem], worth: Double, paid: Double, service: [GearItem]) -> [PageBox] {
        var boxes: [PageBox] = [
            PageBox("numbers", "Key numbers", color: Palette.gold) {
                HStack(spacing: 12) {
                    tile("Items", "\(items.count)", Theme.text)
                    tile("Worth today", Money.string(worth), Palette.gold)
                    tile("Paid", Money.string(paid), Theme.text)
                    tile("Needs a check-up", "\(service.count)", service.isEmpty ? Theme.text : Theme.amber)
                }
            },
        ]
        if !service.isEmpty {
            boxes.append(PageBox("checkup", "Needs a check-up", color: Theme.amber) {
            if let first = service.first {
                HStack(spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.amber)
                    Text("\(first.name) \(first.lastService == nil ? "has never had a check-up" : "hasn't been looked after in over a year")\(first.shoots.map { " and has been on \($0) shoots" } ?? ""). Book one before the next big shoot?")
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("Log a check-up") {
                        var item = first
                        item.lastService = Date()
                        item.serviceNote = "Check-up"
                        money.saveGear(item)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .panel(padding: 14)
                .accentBar(Theme.amber)
            }
            })
        }
        boxes.append(PageBox("items", "All your gear", color: Palette.gold) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Bought").frame(width: 84, alignment: .leading)
                        Text("Paid").frame(width: 84, alignment: .trailing)
                        Text("Worth now").frame(width: 92, alignment: .trailing)
                        Text("Last looked after").frame(minWidth: 70, maxWidth: 170, alignment: .leading).padding(.leading, 18)
                        Text("Shoots").frame(width: 60, alignment: .trailing)
                    }
                    .font(Theme.font(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                    .padding(.bottom, 8)
                    if items.isEmpty {
                        Text("No gear yet. Add the cameras, lenses and drives you use; Lens works out what they're worth.")
                            .font(Theme.font(size: 13)).foregroundStyle(Theme.muted).padding(.vertical, 12)
                    }
                    ForEach(items) { item in
                        Button { editing = item } label: {
                            HStack {
                                HStack(spacing: 10) {
                                    if let f = item.photoFile, let img = NSImage(contentsOf: GearIdentifier.photoURL(f)) {
                                        Image(nsImage: img).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                                    } else {
                                        Image(systemName: item.kind.icon).foregroundStyle(Palette.gold).frame(width: 28)
                                    }
                                    Text(item.name).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.bought.formatted(.dateTime.month(.abbreviated).year())).font(Theme.font(size: 12)).foregroundStyle(Theme.text3).frame(width: 84, alignment: .leading)
                                Text((item.paidIsEstimate == true ? "~" : "") + Money.string(item.paid)).font(Theme.font(size: 13)).monospacedDigit().foregroundStyle(Theme.text3).frame(width: 84, alignment: .trailing)
                                Text(Money.string(item.value())).font(Theme.font(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 92, alignment: .trailing)
                                Text(serviceText(item)).font(Theme.font(size: 12)).foregroundStyle(item.needsService ? Theme.amber : Theme.text3)
                                    .lineLimit(1).frame(minWidth: 70, maxWidth: 170, alignment: .leading).padding(.leading, 18)
                                Text(item.shoots.map(String.init) ?? "—").font(Theme.font(size: 13)).monospacedDigit().foregroundStyle(Theme.text3).frame(width: 60, alignment: .trailing)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                    }
                }
                .panel()
                .accentBar(Palette.gold)

            Text("\"Worth now\" counts down from what you paid to a resale floor of 20% over each item's useful life, and feeds straight into What's it all worth? on Money.")
                    .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
        })
        return boxes
    }

    private var fullBody: some View {
        let items = money.gear.sorted { $0.value() > $1.value() }
        let worth = items.reduce(0) { $0 + $1.value() }, paid = items.reduce(0) { $0 + $1.paid }
        let service = items.filter(\.needsService).sorted { ($0.shoots ?? 0) > ($1.shoots ?? 0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gear").font(Theme.font(size: 30, weight: .bold)).foregroundStyle(Theme.text)
                        Text("Everything you own, what it's worth today, and when it was last looked after.")
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Add from photo") { fromPhoto = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Add gear") {
                        editing = GearItem(name: "", kind: .camera, bought: Date(), paid: 0, lifeYears: 5)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                ArrangeablePage("gear", spacing: 20, boxes: fullBoxes(items: items, worth: worth, paid: paid, service: service))
            }
            .padding(36)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { item in GearEditor(item: item) }
        .sheet(isPresented: $fromPhoto) { GearPhotoImportView() }
    }

    private func tile(_ label: String, _ value: String, _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.font(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(tone)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private func serviceText(_ item: GearItem) -> String {
        guard let last = item.lastService else { return item.needsService ? "Never" : "—" }
        return "\(item.serviceNote ?? "Check-up"), \(last.formatted(.dateTime.month(.abbreviated).year()))"
    }
}

private struct GearEditor: View {
    @EnvironmentObject private var money: MoneyStore
    @Environment(\.dismiss) private var dismiss
    @State var item: GearItem
    @State private var hasService = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name.isEmpty ? "Add gear" : item.name).font(Theme.font(size: 18, weight: .bold))
            Form {
                TextField("Name", text: $item.name, prompt: Text("Sony A7S III"))
                Picker("Type", selection: $item.kind) { ForEach(GearItem.Kind.allCases) { Text($0.label).tag($0) } }
                DatePicker("Bought", selection: $item.bought, displayedComponents: .date)
                TextField("Paid", value: Binding(get: { item.paid }, set: { item.paid = $0; item.paidIsEstimate = nil }), format: .currency(code: "USD").precision(.fractionLength(0)))
                if item.paidIsEstimate == true {
                    Text("This is a rough used price from a photo. Type what you really paid if you know it.").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                }
                Stepper("Useful life: \(Int(item.lifeYears)) years", value: $item.lifeYears, in: 1...15)
                TextField("Serial number", text: Binding(get: { item.serial ?? "" }, set: { item.serial = $0.isEmpty ? nil : $0 }))
                Stepper("Shoots: \(item.shoots ?? 0)", value: Binding(get: { item.shoots ?? 0 }, set: { item.shoots = $0 }), in: 0...999)
                Toggle("Has had a check-up", isOn: $hasService)
                if hasService {
                    DatePicker("Last check-up", selection: Binding(get: { item.lastService ?? Date() }, set: { item.lastService = $0 }), displayedComponents: .date)
                    TextField("What was done", text: Binding(get: { item.serviceNote ?? "" }, set: { item.serviceNote = $0.isEmpty ? nil : $0 }), prompt: Text("Sensor clean"))
                }
                LabeledContent("Worth today", value: Money.string(item.value()))
            }
            .formStyle(.grouped)
            HStack {
                if money.gear.contains(where: { $0.id == item.id }) {
                    Button("Delete") { money.deleteGear(item); dismiss() }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") {
                    if !hasService { item.lastService = nil; item.serviceNote = nil }
                    money.saveGear(item)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 600)
        .onAppear { hasService = item.lastService != nil }
    }
}
