import SwiftUI
import AppKit

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

/// Every page's arrangement, saved on this Mac (not in her business data).
@MainActor
final class PageLayouts: ObservableObject {
    static let shared = PageLayouts()

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
}

/// Lays out a page's boxes in her order. The thin band just outside each box is a grab area: the
/// pointer turns into a hand there, and dragging moves the box while the others slide out of the way,
/// like moving apps on a phone. Right-clicking the band makes a box half width (when `columns`) or hides it.
/// Boxes that aren't showing right now (say, the calendar before Google is connected) keep their
/// place for when they come back.
struct ArrangeablePage: View {
    let page: String
    var columns = false
    var spacing: CGFloat = 22
    let boxes: [PageBox]

    @ObservedObject private var layouts = PageLayouts.shared
    @EnvironmentObject private var appearance: Appearance

    /// The box whose edge the pointer is on, ready to be picked up.
    @State private var ringFor: String?
    /// True for a drag that started inside a box (that's the box's own business, not a move).
    @State private var ignoring = false
    /// The box being dragged, where the pointer is, and where on the box she grabbed it.
    @State private var dragging: String?
    /// Where the pointer is lives outside the page's own state, so moving the mouse only
    /// redraws the floating box, not every chart on the page.
    @State private var tracker = DragTracker()
    /// The box she swapped places with last, so it doesn't flip back and forth on a boundary.
    @State private var lastOver: String?
    @GestureState private var pressing = false
    /// The order while dragging, before it's saved.
    @State private var live: [BoxPlace]?
    @State private var frames: [String: CGRect] = [:]

    init(_ page: String, columns: Bool = false, spacing: CGFloat = 22, boxes: [PageBox]) {
        self.page = page
        self.columns = columns
        self.spacing = spacing
        self.boxes = boxes
    }

    private var key: String { page + "." + (appearance.simple ? "simple" : "everything") }

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
        var id: String { box.id }
    }

    private var shown: [Placed] {
        (live ?? merged()).compactMap { place in
            guard !(place.hidden ?? false), let box = boxes.first(where: { $0.id == place.id }) else { return nil }
            return Placed(box: box, half: columns && (place.half ?? box.half))
        }
    }

    private var hiddenBoxes: [PageBox] {
        merged().filter { $0.hidden ?? false }.compactMap { p in boxes.first { $0.id == p.id } }
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
        withAnimation(.easeInOut(duration: 0.25)) { layouts.save(key, list) }
    }

    // MARK: The page

    var body: some View {
        let list = shown
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows(list), id: \.first!.id) { row in
                if row.count == 2 {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            slot(row[0]).frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                            slot(row[1]).frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 16) { slot(row[0]); slot(row[1]) }
                    }
                } else if row[0].half {
                    // A half box with no partner keeps its width, so it's clear it can take a neighbour.
                    HStack(alignment: .top, spacing: 16) {
                        slot(row[0]).frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                } else {
                    slot(row[0])
                }
            }
            if !hiddenBoxes.isEmpty { hiddenNote }
        }
        .padding(grabWidth)
        .contentShape(Rectangle())
        .padding(-grabWidth)
        .overlay(alignment: .topLeading) { floating }
        .simultaneousGesture(pageDrag)
        .onChange(of: pressing) { _, now in
            // If the Mac cancels the drag (it can when boxes move under the pointer), still put the box down.
            if !now { finish() }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: BoxFrames.self, value: ["_page": g.frame(in: .global)])
        })
        .onPreferenceChange(BoxFrames.self) { all in
            tracker.origin = all["_page"]?.origin ?? .zero
            frames = all.filter { !$0.key.hasPrefix("_") }
        }
    }

    /// How far outside a box's edge she can grab it.
    private let grabWidth: CGFloat = 14

    /// One box in its place: the box itself, or an outline where it will land while it's being dragged.
    /// Around it is a thin band she can grab: the pointer becomes a hand there, and right-click offers more.
    @ViewBuilder
    private func slot(_ p: Placed) -> some View {
        let isDragging = dragging == p.id
        p.box.view
            .opacity(isDragging ? 0 : 1)
            .overlay {
                if isDragging {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Theme.teal.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.teal.opacity(0.06)))
                }
            }
            .overlay {
                if ringFor == p.id && dragging == nil {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.teal.opacity(0.55), lineWidth: 1.5)
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .background {
                Color.clear
                    .padding(-grabWidth)
                    .contentShape(EdgeBand(width: grabWidth), eoFill: true)
                    .onHover { inside in
                        if inside {
                            ringFor = p.id
                            NSCursor.openHand.set()
                        } else if ringFor == p.id {
                            ringFor = nil
                            if dragging == nil { NSCursor.arrow.set() }
                        }
                    }
                    .contextMenu {
                        if columns {
                            Button(p.half ? "Make it wide" : "Make it half width") { change(p.id) { $0.half = !p.half } }
                        }
                        Button("Hide \(p.box.title)") { change(p.id) { $0.hidden = true } }
                        Divider()
                        Button("Put this page back how it was") { withAnimation { layouts.reset(key) } }
                    }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: BoxFrames.self, value: [p.id: g.frame(in: .global)])
            })
    }

    /// The box whose grab band holds this point: just outside a box, never inside one.
    private func box(grabbedAt point: CGPoint) -> String? {
        if frames.values.contains(where: { $0.contains(point) }) { return nil }
        func gap(_ r: CGRect) -> CGFloat {
            max(r.minX - point.x, point.x - r.maxX, 0) + max(r.minY - point.y, point.y - r.maxY, 0)
        }
        return frames.filter { $0.value.insetBy(dx: -grabWidth, dy: -grabWidth).contains(point) }
            .min { gap($0.value) < gap($1.value) }?.key
    }

    /// One drag for the whole page, so it keeps going while boxes are moved around beneath it.
    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { v in
                if dragging == nil {
                    if ignoring { return }
                    guard let id = box(grabbedAt: v.startLocation), let frame = frames[id] else { ignoring = true; return }
                    tracker.grab = CGSize(width: v.startLocation.x - frame.minX, height: v.startLocation.y - frame.minY)
                    tracker.size = frame.size
                    tracker.pointer = v.location
                    live = merged()
                    lastOver = nil
                    ringFor = nil
                    dragging = id
                    NSCursor.closedHand.set()
                }
                guard let id = dragging else { return }
                tracker.pointer = v.location
                reorder(id, at: v.location)
            }
            .onEnded { _ in finish() }
    }

    /// Put the box down where it is now and save the order.
    private func finish() {
        ignoring = false
        guard dragging != nil else { return }
        if let live { layouts.save(key, live) }
        withAnimation(.easeOut(duration: 0.18)) {
            dragging = nil
            live = nil
        }
        lastOver = nil
        NSCursor.arrow.set()
    }

    /// While dragging, the box takes the place of whichever box the pointer is over, and the rest slide along.
    private func reorder(_ id: String, at point: CGPoint) {
        // Only swap once the pointer is well inside another box, and not with the one just swapped.
        let over = frames.first { key, frame in
            key != id && frame.insetBy(dx: frame.width * 0.15, dy: frame.height * 0.15).contains(point)
        }?.key
        guard let over else {
            if !(frames.first { $0.value.contains(point) } != nil) { lastOver = nil }
            return
        }
        guard over != lastOver, var list = live,
              let from = list.firstIndex(where: { $0.id == id }),
              let to = list.firstIndex(where: { $0.id == over }) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: to)
        lastOver = over
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { live = list }
    }

    /// The box itself, following the pointer.
    @ViewBuilder
    private var floating: some View {
        if let id = dragging, let box = boxes.first(where: { $0.id == id }) {
            FloatingBox(tracker: tracker, content: box.view)
        }
    }

    private var hiddenNote: some View {
        let hidden = hiddenBoxes
        return HStack(spacing: 8) {
            Image(systemName: "eye.slash").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            Menu {
                ForEach(hidden) { box in
                    Button("Show \(box.title)") { change(box.id) { $0.hidden = false } }
                }
                if hidden.count > 1 {
                    Divider()
                    Button("Show them all") {
                        var list = merged()
                        for i in list.indices { list[i].hidden = nil }
                        withAnimation { layouts.save(key, list) }
                    }
                }
            } label: {
                Text("\(hidden.count) hidden on this page")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// Where each box sits, so a drag knows what it's over.
private struct BoxFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A band around the edge of a rectangle, `width` wide (filled even-odd, so the middle is left out).
private struct EdgeBand: Shape {
    var width: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(rect.insetBy(dx: width, dy: width))
        return path
    }
}

/// Where the pointer is during a drag. Only the floating box watches it.
@MainActor
private final class DragTracker: ObservableObject {
    @Published var pointer: CGPoint = .zero
    var grab: CGSize = .zero
    var size: CGSize = .zero
    /// Where the page itself sits on screen, to place the floating box within it.
    var origin: CGPoint = .zero
}

/// The box being moved, following the pointer. Its own view, so mouse moves redraw only this.
private struct FloatingBox: View {
    @ObservedObject var tracker: DragTracker
    let content: AnyView

    var body: some View {
        content
            .frame(width: tracker.size.width, height: tracker.size.height, alignment: .topLeading)
            .scaleEffect(1.02)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            .offset(x: tracker.pointer.x - tracker.grab.width - tracker.origin.x,
                    y: tracker.pointer.y - tracker.grab.height - tracker.origin.y)
            .allowsHitTesting(false)
    }
}
