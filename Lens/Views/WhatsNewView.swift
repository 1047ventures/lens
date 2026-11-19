import SwiftUI

/// "What's new" card shown once after an update, so Emma hears about improvements without hunting.
/// To announce something, add a line to the newest entry in `WhatsNew.notes` (or a new entry for a
/// new version). Each line is a short title and one plain sentence.
enum WhatsNew {
    struct Item: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    /// Newest first. `since` is the first version the lines apply to.
    static let notes: [(since: String, items: [Item])] = [
        ("1.0.36", [
            Item(icon: "folder.fill", title: "Everything for a project in one place",
                 detail: "Each project now has tabs for People, Meeting notes, Emails, Proposal and files, Hours and Money, with a count on each."),
            Item(icon: "person.2.fill", title: "People on a project",
                 detail: "Add the directors, interviewees and crew to a project. Their Zoom notes and emails land there, and Lens suggests people it has seen."),
            Item(icon: "video.fill", title: "Zoom notes find the right project",
                 detail: "Lens looks at who was on the call, the meeting name and your project keywords. If it isn't sure, tap Add to put a note on the project, or Move to send it elsewhere. Lens remembers."),
            Item(icon: "doc.richtext.fill", title: "Your proposal on the project",
                 detail: "Open, print or save the proposal as a PDF from the project, and add contracts, treatments and call sheets from Drive or your Mac."),
        ]),
        ("1.0.35", [
            Item(icon: "video.fill", title: "Connect Zoom",
                 detail: "In Log-ins, click Connect Zoom and Lens reads every full Zoom AI summary, old and new, with next steps and who was there. Nothing to upload."),
            Item(icon: "doc.text.fill", title: "Read the whole summary",
                 detail: "Click a meeting note to see all of it, nicely laid out, with a link to open it in Zoom. Ask Lens can search them all too."),
        ]),
        ("1.0.34", [
            Item(icon: "timer", title: "Track your hours",
                 detail: "Start a timer on any project, or add time by hand. A small timer shows in the sidebar while it runs."),
            Item(icon: "creditcard.fill", title: "See what you keep",
                 detail: "Each project shows what you spent and what you keep. Add an expense with its receipt, or tag one in Money in a click."),
        ]),
        ("1.0.33", [
            Item(icon: "person.2.fill", title: "People, everyone you work with",
                 detail: "A new People section gathers your clients, directors, interviewees, crew and vendors, with every deal, project, email, Zoom note and payment on their page."),
            Item(icon: "bell.fill", title: "Never forget a follow-up",
                 detail: "Pick a follow-up date on anyone and Today reminds you. It also points out people on open deals you haven't heard from in a month."),
            Item(icon: "magnifyingglass", title: "Find anyone fast",
                 detail: "Press Shift Command P from anywhere to find a person, or ask Ask Lens things like who you haven't heard from lately."),
        ]),
        ("1.0.32", [
            Item(icon: "bubble.left.and.bubble.right.fill", title: "Ask Lens keeps going",
                 detail: "Long chats in Ask Lens no longer stop with a red error. Ask it anything, as many times as you like."),
        ]),
        ("1.0.29", [
            Item(icon: "tray.and.arrow.down.fill", title: "New inquiries from Gmail",
                 detail: "Lens spots inquiries and booked work in your email and suggests them on Pipeline and Projects. Tap Add or Ignore."),
            Item(icon: "video.fill", title: "Zoom notes on the right client",
                 detail: "Your Zoom AI call summaries show up under Meeting notes on the matching deal or project."),
        ]),
        ("1.0.30", [
            Item(icon: "phone.fill", title: "Your Zoom notes, on every gig",
                 detail: "Zoom's AI call summaries now show up under Meeting notes on the right deal or project, and Ask Lens can read them."),
        ]),
        ("1.0.29", [
            Item(icon: "tray.and.arrow.down.fill", title: "Inquiries from your email",
                 detail: "Lens reads your recent Gmail and suggests new inquiries for Pipeline and booked work for Projects. Tap Add or Ignore."),
        ]),
        ("1.0.18", [
            Item(icon: "mic.fill", title: "Talk instead of type",
                 detail: "Tap the microphone in Ask Lens and just say what you need."),
            Item(icon: "paperclip", title: "Show Ask Lens your files",
                 detail: "Drop in photos, PDFs or documents, or paste a link, and ask about them."),
            Item(icon: "envelope.fill", title: "Google in one click",
                 detail: "Sign in with Google once in Log-ins and Lens can use your Gmail, Drive, Sheets, Docs and Calendar."),
            Item(icon: "camera.fill", title: "Add gear from a photo",
                 detail: "In Gear, choose Add from photo and Lens fills in what it sees."),
            Item(icon: "sparkles", title: "See what cleanup would remove",
                 detail: "In Library, See exactly what's included lists every file before anything is touched."),
            Item(icon: "wand.and.stars", title: "Your ideas ship by themselves",
                 detail: "Ask Lens for a change and it arrives as an update like this one, usually within an hour."),
        ]),
    ]

    private static let seenKey = "whatsNew.seenVersion"
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Lines Emma hasn't seen yet. Someone who has never seen the card gets all of it.
    static func unseen() -> [Item] {
        let seen = UserDefaults.standard.string(forKey: seenKey)
        if seen == currentVersion { return [] }
        guard let seen else { return notes.flatMap(\.items) }
        return notes.filter { newer($0.since, than: seen) }.flatMap(\.items)
    }

    static func markSeen() { UserDefaults.standard.set(currentVersion, forKey: seenKey) }

    private static func newer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}

struct WhatsNewView: View {
    let items: [WhatsNew.Item]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's new in Lens").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("A few things got better since you last looked.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.teal)
                                .frame(width: 30, height: 30)
                                .background(Theme.teal.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(item.detail).font(.system(size: 13)).foregroundStyle(Theme.text3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
            HStack {
                Spacer()
                Button("Got it") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.panel)
    }
}
