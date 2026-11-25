import SwiftUI

// MARK: - Pages she can rearrange

/// One box on a page that can be moved, made half width or hidden.
struct PageBox: Identifiable {
    let id: String
    let title: String
    var color: Color
    /// Starts at half width, side by side with the next half box (pages with columns only).
    var half: Bool
    let view: AnyView

    init<Content: View>(_ id: String, _ title: String, color: Color = Theme.teal, half: Bool = false,
                        @ViewBuilder _ content: () -> Content) {
        self.id = id
        self.title = title
        self.color = color
        self.half = half
        self.view = AnyView(content())
    }
}

/// Where she put one box. Nil fields fall back to the page's own choice, so new defaults still reach her.
struct BoxPlace: Codable, Equatable {
    var id: String
    var half: Bool?
    var hidden: Bool?
}

/// Every page's arrangement, saved on this Mac (not in her business data), plus whether she's arranging now.
@MainActor
final class PageLayouts: ObservableObject {
    static let shared = PageLayouts()

    /// True while the page on screen shows its boxes as tiles to drag.
    @Published var arranging = false
    /// The page on screen that can be arranged, so the toolbar knows to offer Arrange.
    @Published private(set) var current: String?
    @Published private var cache: [String: [BoxPlace]] = [:]

    private func defaultsKey(_ key: String) -> String { "layout." + key }

    func places(_ key: String) -> [BoxPlace]? {
        if let found = cache[key] { return found }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(key)),
              let list = try? JSONDecoder().decode([BoxPlace].self, from: data) else { return nil }
        DispatchQueue.main.async { self.cache[key] = list }
        return list
    }

    func save(_ key: String, _ list: [BoxPlace]) {
        cache[key] = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: defaultsKey(key)) }
    }

    func reset(_ key: String) {
        cache[key] = []
        UserDefaults.standard.removeObject(forKey: defaultsKey(key))
    }

    func appeared(_ page: String) { current = page }

    func disappeared(_ page: String) {
        guard current == page else { return }
        current = nil
        arranging = false
    }
}

/// Lays out a page's boxes in her order. While arranging, each box becomes a tile she can drag,
/// make wide or half (when `columns`), or hide. Boxes that aren't showing right now (say, the calendar
/// before Google is connected) keep their place for when they come back.
struct ArrangeablePage: View {
    let page: String
    var columns = false
    var spacing: CGFloat = 22
    let boxes: [PageBox]

    @ObservedObject private var layouts = PageLayouts.shared
    @EnvironmentObject private var appearance: Appearance
    @State private var target: String?
    /// The tile being dragged, how far it has moved, and where every tile sits, to tell what it's over.
    @State private var dragging: String?
    @State private var offset: CGSize = .zero
    @State private var frames: [String: CGRect] = [:]

    init(_ page: String, columns: Bool = false, spacing: CGFloat = 22, boxes: [PageBox]) {
        self.page = page
        self.columns = columns
        self.spacing = spacing
        self.boxes = boxes
    }

    private var key: String { page + "." + (appearance.simple ? "simple" : "everything") }

    var body: some View {
        Group {
            if layouts.arranging && layouts.current == page { arrangingView } else { pageView }
        }
        .onAppear { layouts.appeared(page) }
        .onDisappear { layouts.disappeared(page) }
    }

    // MARK: Order

    /// Her saved order, with any box she hasn't placed yet slotted in after the box it normally follows.
    private func merged() -> [BoxPlace] {
        var list = layouts.places(key) ?? []
        for (i, box) in boxes.enumerated() where !list.contains(where: { $0.id == box.id }) {
            let before = boxes[..<i].last { b in list.contains { $0.id == b.id } }
            let at = before.flatMap { b in list.firstIndex { $0.id == b.id } }.map { $0 + 1 } ?? 0
            list.insert(BoxPlace(id: box.id), at: at)
        }
        return list
    }

    private struct Placed: Identifiable {
        let box: PageBox
        let half: Bool
        let hidden: Bool
        var id: String { box.id }
    }

    private func placed(includeHidden: Bool) -> [Placed] {
        merged().compactMap { place in
            guard let box = boxes.first(where: { $0.id == place.id }) else { return nil }
            let hidden = place.hidden ?? false
            if hidden && !includeHidden { return nil }
            return Placed(box: box, half: columns && (place.half ?? box.half), hidden: hidden)
        }
    }

    /// Two half boxes in a row share it; anything else gets a row to itself.
    private func rows(_ list: [Placed]) -> [[Placed]] {
        var out: [[Placed]] = []
        var i = 0
        while i < list.count {
            if list[i].half, i + 1 < list.count, list[i + 1].half {
                out.append([list[i], list[i + 1]]); i += 2
            } else {
                out.append([list[i]]); i += 1
            }
        }
        return out
    }

    private func change(_ id: String, _ edit: (inout BoxPlace) -> Void) {
        var list = merged()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        edit(&list[i])
        layouts.save(key, list)
    }

    private func move(_ id: String, to targetID: String?) {
        var list = merged()
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: from)
        if let targetID, let to = merged().firstIndex(where: { $0.id == targetID }) {
            // Dropped on a box: it takes that box's place (after it going down, before it going up).
            list.insert(item, at: min(to, list.count))
        } else {
            list.append(item)
        }
        withAnimation(.easeInOut(duration: 0.2)) { layouts.save(key, list) }
    }

    // MARK: The page

    private var pageView: some View {
        let list = placed(includeHidden: false)
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows(list), id: \.first!.id) { row in
                if row.count == 2 {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            row[0].box.view.frame(minWidth: 340, maxWidth: .infinity)
                            row[1].box.view.frame(minWidth: 340, maxWidth: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 16) { row[0].box.view; row[1].box.view }
                    }
                } else {
                    row[0].box.view
                }
            }
            if list.isEmpty && !boxes.isEmpty {
                Text("Everything on this page is hidden. Click Arrange at the top to bring boxes back.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: Arranging

    private var arrangingView: some View {
        let list = placed(includeHidden: true)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "hand.draw").foregroundStyle(Theme.teal)
                Text(columns ? "Drag the boxes into the order you want. Make any two half width to sit them side by side, and hide the ones you don't need."
                             : "Drag the boxes into the order you want, and hide the ones you don't need.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Back to how it was") { withAnimation { layouts.reset(key) } }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Done") { layouts.arranging = false }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .panel(padding: 14)

            ForEach(rows(list), id: \.first!.id) { row in
                HStack(spacing: 12) {
                    ForEach(row) { tile($0) }
                    if row.count == 1 && row[0].half { Color.clear.frame(maxWidth: .infinity, minHeight: 1) }
                }
            }
            Text("Drop here to move a box to the bottom")
                .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).stroke(target == "_end" ? Theme.teal : Theme.line,
                                                                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .background(GeometryReader { g in
                    Color.clear.preference(key: TileFrames.self, value: ["_end": g.frame(in: .named("arrange"))])
                })
        }
        .coordinateSpace(name: "arrange")
        .onPreferenceChange(TileFrames.self) { frames = $0 }
    }

    private func drag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("arrange"))
            .onChanged { v in
                dragging = id
                offset = v.translation
                target = frames.first { $0.key != id && $0.value.contains(v.location) }?.key
            }
            .onEnded { _ in
                if let t = target { move(id, to: t == "_end" ? nil : t) }
                dragging = nil
                offset = .zero
                target = nil
            }
    }

    private func tile(_ p: Placed) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
            RoundedRectangle(cornerRadius: 2).fill(p.box.color).frame(width: 4, height: 22)
            Text(p.box.title).font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            if p.hidden {
                Text("Hidden").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if columns {
                Button { change(p.id) { $0.half = !p.half } } label: {
                    Label(p.half ? "Make wide" : "Make half", systemImage: p.half ? "rectangle" : "rectangle.split.2x1")
                        .font(Theme.font(size: 12))
                }
                .buttonStyle(.borderless)
                .help(p.half ? "Give this box the whole row" : "Make this box half width, so it can sit beside another")
            }
            Button { change(p.id) { $0.hidden = !p.hidden } } label: {
                Label(p.hidden ? "Show" : "Hide", systemImage: p.hidden ? "eye" : "eye.slash")
                    .font(Theme.font(size: 12))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(target == p.id ? Theme.teal : Theme.line,
                                                           lineWidth: target == p.id ? 2.5 : 1))
        .opacity(p.hidden ? 0.55 : 1)
        .background(GeometryReader { g in
            Color.clear.preference(key: TileFrames.self, value: [p.id: g.frame(in: .named("arrange"))])
        })
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(dragging == p.id ? 0.25 : 0), radius: 12, y: 6)
        .offset(dragging == p.id ? offset : .zero)
        .zIndex(dragging == p.id ? 1 : 0)
        .gesture(drag(p.id))
    }
}

/// Where each tile sits while arranging, so a drag knows what it's over.
private struct TileFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
