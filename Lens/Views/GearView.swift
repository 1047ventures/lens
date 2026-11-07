import SwiftUI

/// Everything Emma owns, what it's worth today (feeds "What's it all worth?" in Money),
/// and when it was last looked after.
struct GearView: View {
    @EnvironmentObject private var money: MoneyStore
    @State private var editing: GearItem?

    var body: some View {
        let items = money.gear.sorted { $0.value() > $1.value() }
        let worth = items.reduce(0) { $0 + $1.value() }, paid = items.reduce(0) { $0 + $1.paid }
        let service = items.filter(\.needsService).sorted { ($0.shoots ?? 0) > ($1.shoots ?? 0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gear").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
                        Text("Everything you own, what it's worth today, and when it was last looked after.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Add gear") {
                        editing = GearItem(name: "", kind: .camera, bought: Date(), paid: 0, lifeYears: 5)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                HStack(spacing: 12) {
                    tile("Items", "\(items.count)", Theme.text)
                    tile("Worth today", Money.string(worth), Palette.gold)
                    tile("Paid", Money.string(paid), Theme.text)
                    tile("Needs a check-up", "\(service.count)", service.isEmpty ? Theme.text : Theme.amber)
                }

                if let first = service.first {
                    HStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.amber)
                        Text("\(first.name) \(first.lastService == nil ? "has never had a check-up" : "hasn't been looked after in over a year")\(first.shoots.map { " and has been on \($0) shoots" } ?? ""). Book one before the next big shoot?")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
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

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Bought").frame(width: 84, alignment: .leading)
                        Text("Paid").frame(width: 84, alignment: .trailing)
                        Text("Worth now").frame(width: 92, alignment: .trailing)
                        Text("Last looked after").frame(width: 170, alignment: .leading).padding(.leading, 18)
                        Text("Shoots").frame(width: 60, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                    .padding(.bottom, 8)
                    if items.isEmpty {
                        Text("No gear yet. Add the cameras, lenses and drives you use; Lens works out what they're worth.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.vertical, 12)
                    }
                    ForEach(items) { item in
                        Button { editing = item } label: {
                            HStack {
                                HStack(spacing: 10) {
                                    Image(systemName: item.kind.icon).foregroundStyle(Palette.gold).frame(width: 18)
                                    Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.bought.formatted(.dateTime.month(.abbreviated).year())).font(.system(size: 12)).foregroundStyle(Theme.text3).frame(width: 84, alignment: .leading)
                                Text(Money.string(item.paid)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text3).frame(width: 84, alignment: .trailing)
                                Text(Money.string(item.value())).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 92, alignment: .trailing)
                                Text(serviceText(item)).font(.system(size: 12)).foregroundStyle(item.needsService ? Theme.amber : Theme.text3)
                                    .lineLimit(1).frame(width: 170, alignment: .leading).padding(.leading, 18)
                                Text(item.shoots.map(String.init) ?? "—").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text3).frame(width: 60, alignment: .trailing)
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
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(36)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { item in GearEditor(item: item) }
    }

    private func tile(_ label: String, _ value: String, _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(tone)
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
            Text(item.name.isEmpty ? "Add gear" : item.name).font(.system(size: 18, weight: .bold))
            Form {
                TextField("Name", text: $item.name, prompt: Text("Sony A7S III"))
                Picker("Type", selection: $item.kind) { ForEach(GearItem.Kind.allCases) { Text($0.label).tag($0) } }
                DatePicker("Bought", selection: $item.bought, displayedComponents: .date)
                TextField("Paid", value: $item.paid, format: .currency(code: "USD").precision(.fractionLength(0)))
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
