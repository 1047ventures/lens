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
        ("2.0.2", [
            Item(icon: "arrow.down.right.circle.fill", title: "Pipeline is now part of Projects",
                 detail: "Every inquiry is a project from the first message, sitting at Quoting. Its quote, options and proposal are right on the project page, with the same steps and buttons as every other project. Mark it as booked and it moves on to Planning. Past quotes and your rates are under Quotes on Projects."),
            Item(icon: "square.grid.2x2.fill", title: "Choose your boxes",
                 detail: "At the bottom of Today there's a new Choose boxes button. Pick from extras like a monthly goal, a weekly checklist, who owes you, your best clients, what you really earn per hour and more. Switch on the ones you like."),
            Item(icon: "number", title: "Pick your numbers",
                 detail: "The number tiles on Today and Money now have Choose numbers under them, so you can keep the ones you care about and add new ones like profit margin and days to get paid."),
            Item(icon: "sun.max.fill", title: "A kinder Today",
                 detail: "Everything now opens with a few things for you, the rest folded away for later, and a plain sentence on each chart saying what it means."),
            Item(icon: "chart.bar.fill", title: "Where your jobs are",
                 detail: "The jobs card on Today now shows each step in plain words, from Quoting to Wrapping up, with how many jobs are there and what they're worth. Rest the pointer on a step to see what it means."),
            Item(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", title: "Click a step to step inside",
                 detail: "The steps across the top of a project now open. Click Planning to see the plan, who's involved and the calls from then. Click Shooting for the footage, Getting paid for the money. Steps ahead show what's coming. In the simple look, click a step to see a short summary of it."),
            Item(icon: "textformat", title: "The same words everywhere",
                 detail: "Every project step now has one name all over Lens: Quoting, Planning, Shooting, Editing, Getting paid, Wrapping up and Put away."),
            Item(icon: "magnifyingglass", title: "Find any project",
                 detail: "Projects has a search box now. Type a client, a place, a month or anyone involved, and Sort by date, place, people involved or client. Projects aren't only for clients either: start one for an idea of your own."),
            Item(icon: "map.fill", title: "Every shoot in a place, in one list",
                 detail: "Click a group of pictures on the Library map and every shoot there is listed right beside it, with when, who and what's in it. Click one to open it."),
            Item(icon: "arrow.uturn.backward.circle.fill", title: "Right where you left off",
                 detail: "Pop over to another part of Lens and come back, and the Library is still on the shoot you were looking at, with the map where you left it. Each project also reopens on the tab you were on."),
            Item(icon: "person.2.crop.square.stack.fill", title: "A shoot, at a glance",
                 detail: "A shoot's photos and videos now start with a short brief: what it was, how far it got, who was involved and what happened last. Sort the files by folder, day, camera or place, and by who's in them or which scene when your files say so."),
        ]),
        ("2.0.1", [
            Item(icon: "photo.on.rectangle.angled", title: "A project's photos and videos, right there",
                 detail: "Each project now shows how many photos and videos Lens has found for it, with a few pictures to glance at. Click them, or See the photos and videos, to look through the whole shoot."),
            Item(icon: "map.fill", title: "From the map to the pictures",
                 detail: "Click a shoot on the Library map and you go straight to its photos and videos. If Lens hasn't found them yet, it shows the folders from around the shoot date so you can pick the right one."),
            Item(icon: "leaf.fill", title: "Simple or Everything, at the top",
                 detail: "The Simple and Everything switch now sits at the top right, next to Ask Lens, so you can flip between them on any screen. Style at the bottom of the sidebar is just for the look."),
            Item(icon: "square.grid.2x2.fill", title: "Arrange any page your way",
                 detail: "Press and hold on any box for a moment, then drag it anywhere on the page (or grab it straight away just outside its edge, where the pointer turns into a hand), and the other boxes slide out of the way. Right-click there to make a box half width so two sit side by side, or to hide it. Hidden boxes wait at the bottom of the page."),
            Item(icon: "book.fill", title: "Your books by day, week, month or year",
                 detail: "The books in Money now have Day, Week, Month and Year tabs. Use the arrows to look back at an earlier one. The main lines stand out, and hovering over one tells you what it means."),
        ]),
        ("2.0.0", [
            Item(icon: "paintpalette.fill", title: "A fresh new look",
                 detail: "Lens has two new looks, Daylight and Evening, in your own brand colours and fonts. The old dark look is still there as Studio. Change it any time with Style at the bottom of the sidebar."),
            Item(icon: "leaf.fill", title: "Simple or Everything",
                 detail: "Simple shows just what you need on every screen: today and this week, who's waiting on you, and the few money numbers that matter. Switch to Everything at the top right, next to Ask Lens, whenever you want every number and option."),
            Item(icon: "photo.stack.fill", title: "Library by shoot",
                 detail: "Library now opens on a map of your shoots, each one where it was shot. Zoom in and click one to open it, or switch to List to sort them by date, place, people, camera, price, paid or not, or which drive they're on. Folders that aren't part of a shoot yet wait below, and Lens asks which project each one is from."),
        ]),
        ("1.0.63", [
            Item(icon: "checkmark.bubble.fill", title: "Teach Lens",
                 detail: "Click Teach Lens in Pipeline and go through your recent email one at a time. Say if Lens got it right, or fix it, and it sorts your email that way from then on."),
            Item(icon: "person.2.fill", title: "One People list per project",
                 detail: "A project's People tab now shows one list, the people really on it. Click a name to open them in People."),
        ]),
        ("1.0.62", [
            Item(icon: "envelope.badge.fill", title: "Lens learns what matters",
                 detail: "Ignore now asks why, and Lens learns from it. Tell Ask Lens which emails and messages matter and it sorts your inbox that way."),
        ]),
        ("1.0.61", [
            Item(icon: "person.2.fill", title: "Your projects, your people",
                 detail: "A project only shows emails with the people on its People list. Lens no longer adds people by itself, and taking someone off with the x takes their emails off too."),
        ]),
        ("1.0.60", [
            Item(icon: "camera.fill", title: "Instagram DMs come in",
                 detail: "Lens now reads your Instagram DMs through your Facebook Page the way Meta asks, so they show up next to your Facebook messages."),
        ]),
        ("1.0.59", [
            Item(icon: "arrow.right", title: "Inquiry, quote, project",
                 detail: "Pipeline is now New inquiries and Quote sent. Uploading a quote moves an inquiry along, and Book it turns it into a project with everything on it."),
            Item(icon: "envelope.badge.shield.half.filled", title: "Only this job's emails",
                 detail: "A project only keeps emails that name the job or include the client. Unrelated ones were cleared."),
            Item(icon: "person.crop.circle.badge.xmark", title: "Delete and hide",
                 detail: "Delete an inquiry from its page, and hide people Lens suggests for a project."),
            Item(icon: "person.crop.circle.badge.checkmark", title: "Only real people in People",
                 detail: "Lens only adds someone when you've actually emailed back and forth, or they filled in your form. Auto-replies and company emails were cleared, and Clear out junk does it again."),
            Item(icon: "slider.horizontal.3", title: "The quote lives on the project",
                 detail: "The project's Proposal tab shows the booked option with its rates, hours and price, ready to edit."),
        ]),
        ("1.0.58", [
            Item(icon: "exclamationmark.bubble.fill", title: "Why Instagram isn't coming in",
                 detail: "If your Instagram DMs don't come through your Facebook Page, Log-ins now shows Meta's reason, so it's clear what to fix."),
        ]),
        ("1.0.57", [
            Item(icon: "bubble.left.and.bubble.right.fill", title: "One code for Facebook and Instagram",
                 detail: "Your Facebook Page code now brings in your Instagram DMs too, when your Instagram is linked to your Page."),
        ]),
        ("1.0.56", [
            Item(icon: "checkmark.seal.fill", title: "Deals finish booking into their project",
                 detail: "A deal attached to a project now leaves Pipeline as won and brings its emails, people and price to the project."),
            Item(icon: "dollarsign.square.fill", title: "Type the price on the project",
                 detail: "The project's Proposal tab has the price as a box. Type the real number and the deal and Money follow."),
        ]),
        ("1.0.55", [
            Item(icon: "pencil.line", title: "Type your own budget",
                 detail: "Every budget line on a deal is now a box you can type in, and the total follows. Each option also has its own day, half day and hourly rate."),
            Item(icon: "arrow.right.circle.fill", title: "From Pipeline to project, with everything",
                 detail: "Mark won can book a deal into a project you already made. Its emails, call notes, people and price all come with it."),
            Item(icon: "dollarsign.circle.fill", title: "The price you type is the price",
                 detail: "Type a price on a quote and the deal and project use it."),
        ]),
        ("1.0.54", [
            Item(icon: "slider.horizontal.3", title: "Your hours, your numbers",
                 detail: "On each option, type your own planning, editing and media hours and gear costs. The budget, workload and what you keep follow your numbers."),
            Item(icon: "trash", title: "Fix or remove a quote",
                 detail: "Each quote has Open, Read again, a price you can type in, and a trash button. Picking the option they chose books the job and makes the project."),
            Item(icon: "envelope.fill", title: "Every email on the deal",
                 detail: "A deal now pulls in every email with its people, however old, not just the one it started from."),
        ]),
        ("1.0.53", [
            Item(icon: "doc.on.doc", title: "Pages and Keynote proposals",
                 detail: "Upload proposals as PDF, Word, Pages, Keynote or a photo. Lens reads the options, prices and what's included."),
            Item(icon: "hammer.fill", title: "Build a quote from a project",
                 detail: "A project without a proposal has Build a quote and Ask Lens to price it, using full days, half days, hours, or images and B-roll only."),
        ]),
        ("1.0.52", [
            Item(icon: "doc.richtext", title: "Your proposal, not a template",
                 detail: "Upload your proposal on a deal or project and it becomes the proposal there: Open your proposal opens your file, and the deal shows your own options and prices."),
            Item(icon: "checkmark.circle.fill", title: "Which option did they choose?",
                 detail: "Pick the option the client went for and Lens uses that price on the deal, the project and Money."),
            Item(icon: "clock.fill", title: "Half days, hours and B-roll only",
                 detail: "Quotes can now use local half days, hours of filming, and edited images and B-roll with no final film. Set your half day and hourly rates in Rates & profile."),
        ]),
        ("1.0.51", [
            Item(icon: "sparkles", title: "Lens finds your projects",
                 detail: "From your email and call notes, Lens adds your current and upcoming projects with their people, and puts possible jobs on Pipeline. Keep or Remove each on Projects."),
            Item(icon: "doc.text.fill", title: "FreshBooks",
                 detail: "Connect it in Log-ins: unpaid invoices show as money owed on the project, and estimates go into Past quotes."),

            Item(icon: "envelope.open.fill", title: "Your whole email history",
                 detail: "Lens reads every work conversation from the last three years and sums up what you discussed and decided, right on each email."),
            Item(icon: "person.crop.rectangle.stack", title: "Contacts and quotes from email",
                 detail: "Phone numbers, companies and roles go into People, and every price you quoted goes into Past quotes."),
        ]),
        ("1.0.50", [
            Item(icon: "doc.badge.arrow.up", title: "Upload proposals and quotes",
                 detail: "On any project or deal, click Upload a proposal or quote. Lens keeps the file there and reads the price and what it covered."),
            Item(icon: "clock.arrow.circlepath", title: "Your past quotes",
                 detail: "Pipeline has Past quotes: everything you've quoted, what was accepted, and your averages. Ask Lens uses them to help price new jobs."),
        ]),
        ("1.0.49", [
            Item(icon: "bubble.left.and.text.bubble.right.fill", title: "Instagram and Facebook messages",
                 detail: "Connect them once in Log-ins and Lens reads your DMs and Page messages every hour. Real inquiries show up on Pipeline."),
            Item(icon: "star.fill", title: "Directories and reviews, no setup",
                 detail: "Leads from The Knot, Thumbtack, Google and more come in by themselves, and your Google reviews are listed in Log-ins."),
        ]),
        ("1.0.48", [
            Item(icon: "phone.fill", title: "Your My Notes calls",
                 detail: "Once Zoom is connected, every call you recorded with Zoom My Notes comes in with its notes and full transcript, and goes on the right project."),
            Item(icon: "text.quote", title: "A summary for every recording",
                 detail: "When a My Notes call only has a recording, Lens writes the summary and next steps for you."),
        ]),
        ("1.0.47", [
            Item(icon: "clock.arrow.circlepath", title: "A project's whole history",
                 detail: "Add people to a project and Lens goes back through all your email and Zoom summaries with them, however old, and puts them on the project."),
            Item(icon: "person.text.rectangle", title: "First names are enough",
                 detail: "A Zoom call that only says Jason or Chloe now goes on the project they're on."),
            Item(icon: "creditcard.fill", title: "Spending finds its project",
                 detail: "Payments that mention a project, its people or its keywords go on that project by themselves."),
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
                Text("What's new in Lens").font(Theme.font(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("A few things got better since you last looked.")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon)
                                .font(Theme.font(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.teal)
                                .frame(width: 30, height: 30)
                                .background(Theme.teal.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(item.detail).font(Theme.font(size: 13)).foregroundStyle(Theme.text3)
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
