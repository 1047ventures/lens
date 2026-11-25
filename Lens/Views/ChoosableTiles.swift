import SwiftUI

// A row of number tiles she picks from.

/// One number she can show. `about` is a plain line on what it tells her.
struct TileOption: Identifiable {
    let id: String
    let label: String
    let about: String
    let tile: AnyView

    init<T: View>(id: String, label: String, about: String, @ViewBuilder tile: () -> T) {
        self.id = id; self.label = label; self.about = about; self.tile = AnyView(tile())
    }
}

/// Lays out the tiles she chose (or the defaults) and offers a quiet "Choose numbers" control.
/// The choice is saved on this Mac under "tiles.<key>" as a list of ids in order.
struct ChoosableTiles: View {
    let options: [TileOption]
    let defaults: [String]
    @AppStorage private var saved: String
    @State private var choosing = false

    init(key: String, options: [TileOption], defaults: [String]) {
        self.options = options
        self.defaults = defaults
        _saved = AppStorage(wrappedValue: "", "tiles.\(key)")
    }

    private var known: Set<String> { Set(options.map(\.id)) }

    /// Saved ids that still exist; the defaults when nothing usable is saved. Never empty.
    private var chosen: [String] {
        let wanted = saved.split(separator: ",").map(String.init).filter { known.contains($0) }
        if !wanted.isEmpty { return wanted }
        let base = defaults.filter { known.contains($0) }
        return base.isEmpty ? Array(options.prefix(1).map(\.id)) : base
    }

    private var shown: [TileOption] { chosen.compactMap { id in options.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            let cards = Group { ForEach(shown) { $0.tile } }
            // One row when there's room, otherwise they wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { cards.frame(minWidth: 170, maxWidth: .infinity) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) { cards }
            }
            Button { choosing = true } label: {
                Label("Choose numbers", systemImage: "slider.horizontal.3")
                    .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $choosing, arrowEdge: .bottom) { picker }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose the numbers you want to see")
                .font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(options) { option in
                        Toggle(isOn: binding(for: option.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).font(Theme.font(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                                Text(option.about).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 380)
            HStack {
                Button("Back to the usual ones") { saved = "" }
                    .buttonStyle(.plain).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Done") { choosing = false }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(id) },
            set: { on in
                var list = chosen
                if on { if !list.contains(id) { list.append(id) } }
                else if list.count > 1 { list.removeAll { $0 == id } }
                saved = list.joined(separator: ",")
            })
    }
}
