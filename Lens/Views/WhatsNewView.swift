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
        ("1.0.47", [
            Item(icon: "waveform", title: "Your Zoom recordings become notes",
                 detail: "Calls you recorded in Zoom without a summary now turn into meeting notes on the right project, written up just like Zoom's."),
            Item(icon: "tag.fill", title: "Where each note came from",
                 detail: "Meeting notes now say Zoom summary, Zoom summary email or Your recording. Ask Lens can search everything said in your recordings."),
        ]),
        ("1.0.46", [
            Item(icon: "eye.fill", title: "Ask Lens sees your screen",
                 detail: "Ask Lens now sees the Lens window just as you do, including what's connected in Log-ins. No more screenshots."),
            Item(icon: "calendar.badge.plus", title: "Acuity bookings become inquiries",
                 detail: "When someone books or fills in your Acuity form, Lens adds them to Pipeline and People by itself."),
        ]),
        ("1.0.42", [
            Item(icon: "chart.bar.xaxis", title: "Today is a dashboard now",
                 detail: "Your day on a timeline, money in by month, lead to paid, where your time went and the week ahead. Click any card to dig in."),
        ]),
        ("1.0.40", [
            Item(icon: "g.circle.fill", title: "Google in one click, really",
                 detail: "Log-ins: click Sign in with Google and you're done. No setup first. Google may say Lens isn't verified: click Advanced, then Go to Lens."),
        ]),
        ("1.0.39", [
            Item(icon: "circle.grid.2x1.fill", title: "Projects as bubbles in People",
                 detail: "Every project and open deal now shows as a bubble under the search box. Click one to see everyone on it, click again to see everyone."),
        ]),
        ("1.0.38", [
            Item(icon: "paintpalette.fill", title: "Each step has its own colour",
                 detail: "Booked, shoot, edit, delivered and paid now each have a colour in a person's history, so you can see where every project stands at a glance."),
        ]),
        ("1.0.37", [
            Item(icon: "person.crop.circle.badge.plus", title: "People add themselves",
                 detail: "Anyone who emails you about work, fills in your website form, messages you on Instagram or Facebook, or joins a Zoom call now goes in People by itself."),
            Item(icon: "person.crop.rectangle.stack.fill", title: "Scan a business card",
                 detail: "Back from an event? Tap Scan a card in People or Today, take a photo with your iPhone or drop in photos, and Lens adds everyone with their card on their page."),
            Item(icon: "square.and.arrow.down.fill", title: "Bring in LinkedIn, Facebook and Instagram",
                 detail: "In People, tap Bring in people and follow the two steps. Lens adds your connections and the people you've messaged with."),
            Item(icon: "clock.arrow.circlepath", title: "Added recently",
                 detail: "The top of People shows who Lens added in the last two weeks and where from. Keep, Edit or Remove each one. Doubles are merged for you."),
        ]),
        ("1.0.36", [
            Item(icon: "tray.full.fill", title: "Lens files things by itself",
                 detail: "Zoom notes, emails and people that clearly belong to a project now go there without a tap."),
            Item(icon: "questionmark.circle.fill", title: "Which project is this for?",
                 detail: "When Lens isn't sure, it asks and lists its best guess first. Pick a project, or choose Not for a project."),
            Item(icon: "plus.circle.fill", title: "Add project, filled in",
                 detail: "When a call or email looks like new work, tap Add project. Lens fills in the name and people, then files anything else from them there too."),
            Item(icon: "arrow.uturn.backward.circle.fill", title: "See what Lens filed",
                 detail: "Each project shows what Lens filed by itself lately, with Move and Not this project. Today lists this week's too."),
        ]),
        ("1.0.35", [
            Item(icon: "folder.fill", title: "Everything for a project in one place",
                 detail: "Each project now has tabs for People, Meeting notes, Emails, Proposal and files, Hours and Money, with a count on each."),
            Item(icon: "person.2.fill", title: "People on a project",
                 detail: "Add the directors, interviewees and crew to a project. Their Zoom notes and emails land there, and Lens suggests people it has seen."),
            Item(icon: "video.fill", title: "Zoom notes find the right project",
                 detail: "Lens looks at who was on the call, the meeting name and your project keywords. If it isn't sure, tap Add to put a note on the project, or Move to send it elsewhere. Lens remembers."),
            Item(icon: "doc.richtext.fill", title: "Your proposal on the project",
                 detail: "Open, print or save the proposal as a PDF from the project, and add contracts, treatments and call sheets from Drive or your Mac."),
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
