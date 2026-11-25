import SwiftUI
import MapKit

/// One thing on the Library map: a shoot, or a folder that isn't part of a shoot yet.
struct MapPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String
    /// An item to show as the pin's picture (a position in `LibraryIndex.items`).
    let sample: Int?
    let target: MapTarget
    /// False for a loose folder, which is drawn quieter than a shoot.
    let isShoot: Bool
    /// For the list of everything at one spot: when it was shot, a line about it, what's in it, and its step.
    var date: Date? = nil
    var detail: String = ""
    var counts: String = ""
    var stage: String? = nil
}

/// Where clicking a pin goes: a shoot or folder in the Library, or a project with no footage found yet.
enum MapTarget {
    case library(FootageRoute)
    case project(UUID)
}

/// Pins close enough together at the current zoom to show as one, with a count.
struct PinCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let pins: [MapPin]
}

enum MapSpot {
    /// The spot most of these photos and videos were taken: the busiest ~100 m square, averaged.
    static func common(_ items: [LibraryItem]) -> CLLocationCoordinate2D? {
        var buckets: [String: (n: Int, lat: Double, lon: Double)] = [:]
        for item in items {
            guard let lat = item.lat, let lon = item.lon else { continue }
            let key = String(format: "%.3f,%.3f", lat, lon)
            var b = buckets[key] ?? (0, 0, 0)
            b.n += 1; b.lat += lat; b.lon += lon
            buckets[key] = b
        }
        guard let best = buckets.values.max(by: { $0.n < $1.n }) else { return nil }
        return CLLocationCoordinate2D(latitude: best.lat / Double(best.n), longitude: best.lon / Double(best.n))
    }
}

/// Where the Library map was left: its view, zoom and the list that was open, so coming back
/// from a shoot (or from another section) finds the map just as she left it.
@MainActor
final class MapMemory {
    static let shared = MapMemory()
    var region: MKCoordinateRegion?
    var span: Double?
    var stack: PinCluster?
    /// The pins the map was last fitted to; when they change (a search, a new shoot) it fits again.
    var pinsKey = ""
}

/// The Library as a map, the way the Photos app shows Places: a picture where each shoot happened,
/// grouped with a count when zoomed out. Click one to open it; click a group to list everything in it beside the map.
struct LibraryMapView: View {
    let pins: [MapPin]
    let open: (MapTarget) -> Void

    @State private var position: MapCameraPosition = .automatic
    /// How much of the world is showing, in degrees, so nearby pins can be grouped to suit.
    @State private var span: Double?
    /// The group she clicked, listed beside the map so she can pick one without zooming or scrolling.
    @State private var stack: PinCluster?

    var body: some View {
        let groups = clusters(at: span ?? startingSpan)
        Map(position: $position) {
            ForEach(groups) { group in
                Annotation(label(group), coordinate: group.coordinate, anchor: .bottom) {
                    PinBubble(cluster: group, label: label(group))
                        .onTapGesture { tap(group) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            span = max(context.region.span.latitudeDelta, context.region.span.longitudeDelta)
            memory.region = context.region
            memory.span = span
        }
        .onAppear { restoreOrFit() }
        .onChange(of: pinsKey) { _, key in
            guard key != memory.pinsKey else { return }
            memory.pinsKey = key
            fitAll()
        }
        .onChange(of: stack?.id) { _, _ in memory.stack = stack }
        .frame(height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        .overlay(alignment: .topTrailing) {
            if let stack { placeList(stack).padding(12).transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.2), value: stack?.id)
        .overlay(alignment: .topLeading) {
            if pins.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No shoots on the map yet").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Add a place to a project and it shows up here.")
                        .font(Theme.font(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel(padding: 12)
                .frame(width: 250)
                .padding(14)
            }
        }
    }

    private func label(_ group: PinCluster) -> String {
        if group.pins.count == 1 {
            let title = group.pins[0].title
            return title.count > 24 ? String(title.prefix(22)).trimmingCharacters(in: .whitespaces) + "…" : title
        }
        let shoots = group.pins.filter(\.isShoot).count
        if shoots == group.pins.count { return "\(shoots) shoots" }
        return "\(group.pins.count) here"
    }

    private var memory: MapMemory { MapMemory.shared }
    private var pinsKey: String { pins.map(\.id).sorted().joined(separator: ",") }

    /// Back to where she left the map, if these are the same pins; otherwise frame them all.
    private func restoreOrFit() {
        if memory.pinsKey == pinsKey, let region = memory.region {
            position = .region(region)
            span = memory.span
            stack = memory.stack
        } else {
            memory.pinsKey = pinsKey
            fitAll()
        }
    }

    /// Frames every pin, with room above each one for its picture (pins hang from their spot).
    private func fitAll() {
        stack = nil
        guard let first = pins.first else {
            // Nothing to show yet: a wide view of the US rather than the whole world.
            position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39, longitude: -97),
                                                  span: MKCoordinateSpan(latitudeDelta: 32, longitudeDelta: 62)))
            return
        }
        var minLat = first.coordinate.latitude, maxLat = minLat
        var minLon = first.coordinate.longitude, maxLon = minLon
        for p in pins {
            minLat = min(minLat, p.coordinate.latitude); maxLat = max(maxLat, p.coordinate.latitude)
            minLon = min(minLon, p.coordinate.longitude); maxLon = max(maxLon, p.coordinate.longitude)
        }
        let latSpan = max((maxLat - minLat) * 1.6, 0.08)
        let lonSpan = max((maxLon - minLon) * 1.3, 0.08)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 + latSpan * 0.08,
                                            longitude: (minLon + maxLon) / 2)
        position = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)))
        stack = nil
    }

    /// Before the map reports its zoom, group as if it shows every pin.
    private var startingSpan: Double {
        guard let first = pins.first else { return 40 }
        var minLat = first.coordinate.latitude, maxLat = minLat
        var minLon = first.coordinate.longitude, maxLon = minLon
        for p in pins {
            minLat = min(minLat, p.coordinate.latitude); maxLat = max(maxLat, p.coordinate.latitude)
            minLon = min(minLon, p.coordinate.longitude); maxLon = max(maxLon, p.coordinate.longitude)
        }
        return max(max(maxLat - minLat, maxLon - minLon) * 1.4, 0.05)
    }

    /// Groups pins that would sit on top of each other at this zoom. Each pin joins the first group
    /// whose middle is within about a seventh of the view, so neighbours never overlap each other's names.
    private func clusters(at span: Double) -> [PinCluster] {
        let near = max(span / 7, 0.0005)
        // Shoots first, so a group's picture is a shoot rather than a loose folder.
        let ordered = pins.sorted { ($0.isShoot ? 0 : 1, $0.title) < ($1.isShoot ? 0 : 1, $1.title) }
        var groups: [(lat: Double, lon: Double, pins: [MapPin])] = []
        for pin in ordered {
            let lat = pin.coordinate.latitude, lon = pin.coordinate.longitude
            if let i = groups.firstIndex(where: { abs($0.lat - lat) < near && abs($0.lon - lon) < near }) {
                let n = Double(groups[i].pins.count)
                groups[i].lat = (groups[i].lat * n + lat) / (n + 1)
                groups[i].lon = (groups[i].lon * n + lon) / (n + 1)
                groups[i].pins.append(pin)
            } else {
                groups.append((lat, lon, [pin]))
            }
        }
        return groups.map { g in
            PinCluster(id: g.pins.map(\.id).joined(separator: ","),
                       coordinate: CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon), pins: g.pins)
        }
        .sorted { $0.coordinate.latitude > $1.coordinate.latitude }
    }

    private func tap(_ group: PinCluster) {
        if group.pins.count == 1 { stack = nil; open(group.pins[0].target); return }
        stack = group
    }

    /// Everything under the bubble she clicked, newest shoot first, with loose folders after.
    private func placeList(_ group: PinCluster) -> some View {
        let shoots = group.pins.filter(\.isShoot).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let loose = group.pins.filter { !$0.isShoot }.sorted { $0.title < $1.title }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading(shoots: shoots.count, loose: loose.count))
                    .font(Theme.display(size: 17)).foregroundStyle(Theme.text)
                Spacer()
                Button { stack = nil } label: {
                    Image(systemName: "xmark").font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24).background(Circle().fill(Theme.raised))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shoots) { pin in PlaceRow(pin: pin) { open(pin.target) } }
                    if !loose.isEmpty {
                        Text("Not sorted yet").font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8).padding(.top, shoots.isEmpty ? 0 : 10).padding(.bottom, 2)
                        ForEach(loose) { pin in PlaceRow(pin: pin) { open(pin.target) } }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
        .frame(width: 330)
        .frame(maxHeight: 516)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private func heading(shoots: Int, loose: Int) -> String {
        if loose == 0 { return "\(shoots) shoot\(shoots == 1 ? "" : "s") here" }
        if shoots == 0 { return "\(loose) folder\(loose == 1 ? "" : "s") here" }
        return "\(shoots) shoot\(shoots == 1 ? "" : "s"), \(loose) folder\(loose == 1 ? "" : "s")"
    }
}

/// One shoot or folder in the list beside the map: its picture, name, when and who, and what's in it.
private struct PlaceRow: View {
    let pin: MapPin
    let action: () -> Void
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var catalog = DriveCatalog.shared
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                picture
                    .frame(width: 54, height: 54)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.title).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if !pin.detail.isEmpty {
                        Text(pin.detail).font(Theme.font(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if !pin.counts.isEmpty {
                            Text(pin.counts).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                        }
                        if let stage = pin.stage {
                            Text(stage).font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.raised))
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.raised.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var picture: some View {
        if let i = pin.sample, index.items.indices.contains(i) {
            let item = index.items[i]
            Thumbnail(url: LibraryFiles.url(of: item, catalog: catalog), assetID: item.assetID, kind: item.kind)
        } else {
            Image(systemName: pin.isShoot ? "photo" : "folder").font(Theme.font(size: 18)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A shoot's picture on the map, with its name underneath and a count when it stands for several.
private struct PinBubble: View {
    let cluster: PinCluster
    let label: String
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var catalog = DriveCatalog.shared

    /// The pin whose picture stands for the group: the first shoot with a photo, so it isn't a film icon.
    private var lead: MapPin {
        cluster.pins.first { pin in
            guard pin.isShoot, let i = pin.sample, index.items.indices.contains(i) else { return false }
            return index.items[i].kind == .photo
        } ?? cluster.pins[0]
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                picture
                    .frame(width: 58, height: 58)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(lead.isShoot ? Theme.panel : Theme.muted,
                                style: StrokeStyle(lineWidth: 3, dash: lead.isShoot ? [] : [4, 3])))
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                if cluster.pins.count > 1 {
                    Text("\(cluster.pins.count)")
                        .font(Theme.font(size: 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.onTeal)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.teal))
                        .offset(x: 8, y: -8)
                }
            }
            Text(label)
                .font(Theme.font(size: 11, weight: .semibold))
                .foregroundStyle(lead.isShoot ? Theme.text : Theme.text3)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.panel.opacity(0.95)))
                .overlay(Capsule().stroke(Theme.line))
        }
        .contentShape(Rectangle())
        .help(cluster.pins.map(\.title).joined(separator: ", "))
    }

    @ViewBuilder private var picture: some View {
        if let i = lead.sample, index.items.indices.contains(i) {
            let item = index.items[i]
            Thumbnail(url: LibraryFiles.url(of: item, catalog: catalog), assetID: item.assetID, kind: item.kind)
        } else {
            Image(systemName: "photo").font(Theme.font(size: 20)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
