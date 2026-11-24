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

/// The Library as a map, the way the Photos app shows Places: a picture where each shoot happened,
/// grouped with a count when zoomed out. Click one to open it; click a group to zoom in.
struct LibraryMapView: View {
    let pins: [MapPin]
    let open: (MapTarget) -> Void

    @State private var position: MapCameraPosition = .automatic
    /// How much of the world is showing, in degrees, so nearby pins can be grouped to suit.
    @State private var span: Double?
    /// A group of shoots at the very same spot, listed so she can pick one.
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
        }
        .onAppear { fitAll() }
        .onChange(of: pins.map(\.id)) { _, _ in fitAll() }
        .frame(height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        .overlay(alignment: .bottomLeading) {
            if let stack { stackList(stack).padding(14) }
        }
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
        if group.pins.count == 1 { open(group.pins[0].target); return }
        let lats = group.pins.map(\.coordinate.latitude), lons = group.pins.map(\.coordinate.longitude)
        let spread = max((lats.max()! - lats.min()!), (lons.max()! - lons.min()!))
        if spread < 0.002 {
            // All at one spot: zooming won't pull them apart, so list them.
            stack = group
            return
        }
        stack = nil
        let center = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2, longitude: (lons.max()! + lons.min()!) / 2)
        let size = spread * 1.6 + 0.01
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: size, longitudeDelta: size)))
        }
    }

    private func stackList(_ group: PinCluster) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("At this spot").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { stack = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain)
                    .help("Close")
            }
            ForEach(group.pins) { pin in
                Button { open(pin.target) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pin.isShoot ? "photo.stack" : "folder")
                            .foregroundStyle(Theme.text3).frame(width: 16)
                        Text(pin.title).font(Theme.font(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(Theme.font(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .panel(padding: 14)
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
