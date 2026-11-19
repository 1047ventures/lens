import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Added recently

/// Who Lens added by itself in the last two weeks, and from where. Each one stays unless Emma removes them.
struct RecentlyAddedPanel: View {
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @State private var showAll = false
    @State private var editing: Person?

    var body: some View {
        let recent = people.recentlyAdded
        if !recent.isEmpty {
            let shown = showAll ? recent : Array(recent.prefix(5))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ColorLabel("Added recently · \(recent.count)", Palette.blue)
                    Spacer()
                    Button("Keep all") { people.keepAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                }
                Text("People Lens added by itself in the last two weeks. They stay unless you remove them.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                ForEach(shown) { p in
                    HStack(alignment: .center, spacing: 12) {
                        Button { navigator.personID = p.id } label: {
                            HStack(spacing: 10) {
                                PersonBadge(person: p, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text(detail(p)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Remove") { people.delete(p) }.buttonStyle(SecondaryButtonStyle())
                        Button("Edit") { editing = p }.buttonStyle(SecondaryButtonStyle())
                        Button("Keep") { people.keep(p) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                if recent.count > 5 {
                    Button(showAll ? "Show fewer" : "Show all \(recent.count)") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                }
            }
            .panel()
            .accentBar(Palette.blue)
            .sheet(item: $editing) { p in
                PersonEditor(initial: p) { edited in
                    var kept = edited
                    kept.reviewed = true
                    people.update(kept)
                }
            }
        }
    }

    private func detail(_ p: Person) -> String {
        var parts: [String] = []
        if let from = p.fromText { parts.append(from) }
        if !p.subtitle.isEmpty, p.subtitle != p.name { parts.append(p.subtitle) }
        if let on = p.addedOn {
            parts.append(Calendar.current.isDateInToday(on) ? "today" : on.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Scan a card

/// "Scan a card": take a photo with the iPhone, pick photos, or drop them in. Claude reads each card and
/// Lens adds the person, tagged "Met at networking", with the photo on their page. When Lens isn't sure
/// about something, it shows the card so Emma can check it before adding.
struct CardScanView: View {
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id = UUID()
        var jpeg: Data
        var image: NSImage?
        var photoFile: String?
        var loading = true
        var error: String?
        var card = CardReader.Card()
        var addedID: UUID?
    }

    static let tag = "Met at networking"

    @State private var rows: [Row] = []
    @State private var metOn = Date()
    @State private var dropping = false
    @StateObject private var camera = CameraMenu()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scan business cards").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            if !CardReader.hasKey {
                Text("Lens needs your Claude key to read cards. Add it in Log-ins, then come back.")
                    .font(.system(size: 13)).foregroundStyle(Theme.amber)
            } else {
                Text("Take a photo of a card with your iPhone, or pick or drop in photos. Several cards at once is fine, even in one photo. Lens adds each person to People, tagged Met at networking.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Take a photo with your iPhone") { camera.show() }
                        .buttonStyle(PrimaryButtonStyle())
                        .background(CameraAnchor(menu: camera) { add(image: $0) })
                    Button("Choose photos") { choose() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    DatePicker("Met on", selection: $metOn, displayedComponents: .date)
                        .fixedSize()
                        .font(.system(size: 12))
                }
                ScrollView {
                    VStack(spacing: 10) {
                        if rows.isEmpty { dropZone }
                        ForEach($rows) { $row in card($row) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                if !rows.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 660, height: 620)
        .background(Theme.ground)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            drop(providers)
            return true
        }
    }

    private var summary: String {
        let added = rows.filter { $0.addedID != nil }.count
        let waiting = rows.filter { !$0.loading && $0.addedID == nil && $0.error == nil }.count
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added to People") }
        if waiting > 0 { parts.append("\(waiting) to check") }
        return parts.joined(separator: " · ")
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 28)).foregroundStyle(Theme.muted)
            Text("Or drop photos of cards here")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(dropping ? Theme.teal.opacity(0.1) : Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropping ? Theme.teal : Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    private func card(_ row: Binding<Row>) -> some View {
        let r = row.wrappedValue
        let checking = !r.loading && r.addedID == nil && r.error == nil
        return HStack(alignment: .top, spacing: 14) {
            Group {
                if let img = r.image {
                    Image(nsImage: img).resizable().scaledToFit()
                } else { Rectangle().fill(Theme.raised) }
            }
            .frame(width: checking ? 220 : 110, height: checking ? 150 : 76)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if r.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading this card...").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let e = r.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(e).font(.system(size: 12)).foregroundStyle(Theme.amber)
                    Button("Remove") { rows.removeAll { $0.id == r.id } }.buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let id = r.addedID {
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.card.name.isEmpty ? r.card.email : r.card.name)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text([r.card.title, r.card.company].filter { !$0.isEmpty }.joined(separator: " at "))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint)
                        Text("Added to People").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        Button("Open") {
                            navigator.openPerson(id)
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lens isn't sure about everything on this card. Check the highlighted parts, then tap Add.")
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    field("Name", row.card.name, unsure: r.card.unsure.contains("name"))
                    field("Company", row.card.company, unsure: r.card.unsure.contains("company"))
                    field("Title", row.card.title, unsure: r.card.unsure.contains("title"))
                    field("Email", row.card.email, unsure: r.card.unsure.contains("email"))
                    field("Phone", row.card.phone, unsure: r.card.unsure.contains("phone"))
                    field("Website", row.card.website, unsure: r.card.unsure.contains("website"))
                    field("Instagram", row.card.instagram, unsure: r.card.unsure.contains("instagram"))
                    HStack {
                        Spacer()
                        Button("Skip") { rows.removeAll { $0.id == r.id } }.buttonStyle(SecondaryButtonStyle())
                        Button("Add") { addPerson(r.id) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(r.card.name.trimmingCharacters(in: .whitespaces).isEmpty && !r.card.email.contains("@"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panel(padding: 12)
    }

    private func field(_ label: String, _ text: Binding<String>, unsure: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(unsure ? Theme.amber : Theme.muted).frame(width: 70, alignment: .leading)
            TextField(label, text: text)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(unsure ? Theme.amber : .clear))
        }
    }

    // MARK: Photos in

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose photos of business cards"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url: url) }
    }

    private func drop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add(url: url) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage { Task { @MainActor in add(image: image) } }
                }
            }
        }
    }

    private func add(url: URL) {
        guard let jpeg = GearIdentifier.jpeg(from: url, maxSide: 2000) else { return }
        read(jpeg)
    }

    private func add(image: NSImage) {
        guard let jpeg = GearIdentifier.jpeg(from: image, maxSide: 2000) else { return }
        read(jpeg)
    }

    /// Reads one photo. Each card in it becomes a row; cards Lens is sure about are added straight away.
    private func read(_ jpeg: Data) {
        let row = Row(jpeg: jpeg, image: NSImage(data: jpeg))
        rows.append(row)
        let id = row.id
        Task {
            do {
                let cards = try await CardReader.read(jpeg: jpeg)
                guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
                if cards.isEmpty {
                    rows[i].loading = false
                    rows[i].error = "Lens couldn't find a business card in this photo."
                    return
                }
                let photo = CardReader.keepPhoto(jpeg)
                var made: [Row] = []
                for c in cards {
                    var r = Row(jpeg: jpeg, image: rows[i].image, photoFile: photo, loading: false)
                    r.card = c
                    if c.unsure.isEmpty { r.addedID = people.addFromCard(person(from: c, photo: photo)) }
                    made.append(r)
                }
                rows.replaceSubrange(i...i, with: made)
            } catch {
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    rows[i].loading = false
                    rows[i].error = error.localizedDescription
                }
            }
        }
    }

    private func addPerson(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        var c = rows[i].card
        c.email = c.email.trimmingCharacters(in: .whitespaces).lowercased()
        rows[i].card = c
        rows[i].addedID = people.addFromCard(person(from: c, photo: rows[i].photoFile))
    }

    private func person(from c: CardReader.Card, photo: String?) -> Person {
        let name = c.name.trimmingCharacters(in: .whitespaces)
        var p = Person(name: name.isEmpty ? c.email : name, emails: c.email.contains("@") ? [c.email] : [])
        p.company = c.company
        p.role = c.title
        p.phone = c.phone
        let handle = c.instagram.trimmingCharacters(in: .whitespaces)
        p.link = handle.isEmpty ? c.website : (handle.hasPrefix("@") ? handle : "@" + handle)
        if !handle.isEmpty, !c.website.isEmpty { p.notes = "Website: \(c.website)" }
        p.met = "Networking event"
        p.addTag(Self.tag)
        p.metOn = metOn
        p.addedFrom = "a business card"
        p.cardPhotos = photo.map { [$0] }
        return p
    }
}

// MARK: - Taking a photo with the iPhone (Continuity Camera)

/// Pops up the Mac's "Take Photo" menu for a nearby iPhone or iPad. The photo comes back as an image.
@MainActor
final class CameraMenu: ObservableObject {
    weak var view: CameraAnchorView?
    func show() { view?.showMenu() }
}

struct CameraAnchor: NSViewRepresentable {
    let menu: CameraMenu
    let onImage: (NSImage) -> Void

    func makeNSView(context: Context) -> CameraAnchorView {
        let view = CameraAnchorView()
        view.onImage = onImage
        menu.view = view
        return view
    }

    func updateNSView(_ view: CameraAnchorView, context: Context) {
        view.onImage = onImage
        menu.view = view
    }
}

final class CameraAnchorView: NSView, NSServicesMenuRequestor {
    var onImage: ((NSImage) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func showMenu() {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Take a photo with your iPhone", action: nil, keyEquivalent: "")
        // The Mac fills this in with "Take Photo" for each iPhone or iPad nearby.
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(pasteboard: pasteboard) else { return false }
        onImage?(image)
        return true
    }
}

// MARK: - Bring in LinkedIn, Facebook and Instagram

struct BringInSheet: View {
    let kind: PeopleImport.Kind
    @EnvironmentObject private var people: PeopleStore
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var result: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            Text(intro).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                step(1, stepOne)
                step(2, "Download it from that email. Then tap Find it in Downloads, or Choose the file if you saved it somewhere else. The zip file is fine, no need to open it.")
                Link(kind == .linkedIn ? "Open LinkedIn's download page" : "Open Meta's download page", destination: pageURL)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 30)
            }
            .panel()
            HStack(spacing: 10) {
                Button("Find it in Downloads") { findInDownloads() }.buttonStyle(PrimaryButtonStyle())
                Button("Choose the file") { choose() }.buttonStyle(SecondaryButtonStyle())
            }
            .disabled(working)
            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your download...").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Palette.mint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var intro: String {
        switch kind {
        case .linkedIn:
            return "LinkedIn doesn't let apps read your connections, but it will send you a copy. Lens adds everyone in it with their company, title, email when they share it, and the day you connected."
        case .meta:
            return "Facebook and Instagram will send you a copy of your messages. Lens adds the people you've messaged with. It only reads their names, not what you wrote."
        }
    }

    private var stepOne: String {
        switch kind {
        case .linkedIn:
            return "On LinkedIn, go to Settings, then Data privacy, then Get a copy of your data. Pick Connections and tap Request archive. LinkedIn emails you when it's ready, usually in about 10 minutes."
        case .meta:
            return "In Facebook or Instagram, open Accounts Center, then Your information and permissions, then Download your information. Pick Messages, set the format to JSON, and request it. Meta emails you when it's ready, which can take a few hours. Do this once for each if you use both."
        }
    }

    private var pageURL: URL {
        switch kind {
        case .linkedIn: return URL(string: "https://www.linkedin.com/mypreferences/d/download-my-data")!
        case .meta: return URL(string: "https://accountscenter.facebook.com/info_and_permissions/dyi")!
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Theme.teal.opacity(0.18))
                .foregroundStyle(Theme.teal)
                .clipShape(Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func findInDownloads() {
        guard let url = PeopleImport.findInDownloads(kind) else {
            problem = kind == .linkedIn
                ? "Lens didn't find a LinkedIn download in Downloads yet. If you saved it somewhere else, tap Choose the file."
                : "Lens didn't find a Facebook or Instagram download in Downloads yet. If you saved it somewhere else, tap Choose the file."
            return
        }
        bringIn(url)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = kind == .linkedIn ? [.commaSeparatedText, .zip, .folder] : [.zip, .folder, .json]
        panel.directoryURL = PeopleImport.downloads
        panel.message = kind == .linkedIn ? "Choose your LinkedIn download" : "Choose your Facebook or Instagram download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bringIn(url)
    }

    private func bringIn(_ url: URL) {
        working = true
        problem = nil
        result = nil
        let kind = kind
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    kind == .linkedIn ? try PeopleImport.linkedIn(url) : try PeopleImport.meta(url)
                }.value
                let r = people.bringIn(found)
                result = describe(r)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't read that download."
            }
            working = false
        }
    }

    private func describe(_ r: PeopleStore.BringInResult) -> String {
        func count(_ n: Int) -> String { n == 1 ? "1 person" : "\(n) people" }
        var parts = ["Added \(count(r.added)) to People."]
        if r.alreadyHere > 0 {
            parts.append(r.alreadyHere == 1 ? "1 was already here, so Lens filled in anything missing."
                                            : "\(r.alreadyHere) were already here, so Lens filled in anything missing.")
        }
        if r.leftOut > 0 { parts.append("\(count(r.leftOut)) you removed before stayed out.") }
        return parts.joined(separator: " ")
    }
}
