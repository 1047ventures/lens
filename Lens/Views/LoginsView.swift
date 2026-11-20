import SwiftUI

/// Every account Lens needs, what it gets from each, and the exact steps to connect it.
/// Lens never sees or stores passwords: each connection uses the service's own sign-in,
/// a Mac permission prompt, or something the user already has (like email notifications).
struct LoginsView: View {
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var navigator: Navigator
    @State private var expanded: Set<LoginID> = []

    private struct Group: Identifiable {
        let id: String
        let color: Color
        let note: String
        let items: [LoginID]
    }

    private let groups = [
        Group(id: "Google account", color: Palette.blue, note: "One sign-in covers most of what Lens reads.", items: [.google, .calendar, .drive]),
        Group(id: "Calls", color: Palette.violet, note: "Zoom already records and summarizes your calls.", items: [.zoom]),
        Group(id: "Where clients find you", color: Palette.orchid, note: "Every way a new inquiry can arrive.", items: [.website, .social, .directories]),
        Group(id: "Money", color: Palette.lime, note: "You log in on their own sites. Lens only reads statements.", items: [.freshbooks, .bank, .paypal, .venmo]),
        Group(id: "Lens itself", color: Palette.violet, note: "Ask Lens, and sending feature ideas.", items: [.claude, .github]),
        Group(id: "Coming later", color: Palette.slate, note: "", items: [.homeServer]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            ColorLabel(group.id, group.color)
                            Text(group.note).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        ForEach(group.items) { id in
                            card(id, color: group.color)
                        }
                    }
                }
                Text("Access can be removed any time, here or from each service's own security settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(40)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            logins.importGoogleClient()
            logins.refreshCalendar()
            if !logins.googleConnected || logins.googleNeedsNewSignIn { expanded.insert(.google) }
            Task { await logins.refreshGoogleCalendars() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            logins.importGoogleClient()
            logins.refreshCalendar()
        }
    }

    /// The most useful account still to connect: Google first, then the rest in order.
    private var nextUp: LoginID? {
        LoginID.allCases.first { id in
            let s = logins.status(id)
            return !s.isConnected && !s.isLater
        }
    }

    private var header: some View {
        let p = logins.progress
        return VStack(alignment: .leading, spacing: 12) {
            Text("Log-ins").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
            Text("Everything Lens needs to see the whole business. Lens never sees or stores passwords: each one opens the service's own sign-in, or uses something you already have.")
                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Your Google account").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                TextField("Filled in when you sign in with Google", text: Binding(get: { logins.field("ownerEmail") }, set: { logins.setField("ownerEmail", $0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                Text("Lens ignores any other account on this Mac.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 14) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.teal).frame(width: geo.size.width * CGFloat(p.done) / CGFloat(max(p.total, 1)))
                    }
                }
                .frame(width: 240, height: 6)
                Text("\(p.done) of \(p.total) connected").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            if let next = nextUp, let info = Self.info[next] {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.amber)
                    Text("Next: \(info.name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(next == .google ? "This one unlocks email, Calendar and project folders." : info.covers)
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Button("Open") { expanded.insert(next) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(12)
                .background(Theme.amber.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Everything that can be connected is connected.").font(.system(size: 13)).foregroundStyle(Theme.teal)
            }
        }
    }

    // MARK: Card

    private func card(_ id: LoginID, color: Color) -> some View {
        let info = Self.info[id]!
        let status = logins.status(id)
        let isOpen = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(id) } else { expanded.insert(id) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: info.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 36, height: 36)
                        .background(color.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(info.covers).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 3) {
                        pill(status)
                        Text(status.detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider().overlay(Theme.line)
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LENS GETS").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(color)
                        ForEach(info.gets, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(color).frame(width: 5, height: 5)
                                Text(line).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !info.never.isEmpty {
                            Text("NEVER").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(Theme.muted).padding(.top, 6)
                            Text(info.never).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 280, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("YOU DO").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(color)
                        ForEach(Array(info.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(color).frame(width: 14)
                                Text(.init(step)).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        controls(id).padding(.top, 6)
                    }
                }
                .padding(18)
            }
        }
        .background(Theme.panel)
        .accentBar(status.isConnected ? Theme.teal : color)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    private func pill(_ status: LoginStatus) -> some View {
        let tone: Color
        switch status {
        case .connected: tone = Theme.teal
        case .partial: tone = Theme.amber
        case .todo: tone = Theme.coral
        case .later: tone = Theme.muted
        }
        return Text(status.label)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.opacity(0.18))
            .foregroundStyle(tone)
            .clipShape(Capsule())
    }

    // MARK: Per-account controls

    @ViewBuilder
    private func controls(_ id: LoginID) -> some View {
        switch id {
        case .google: GoogleControls()
        case .calendar: calendarControls
        case .drive: driveControls
        case .zoom: ZoomControls()
        case .website:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Your website, e.g. yourname.com", text: Binding(get: { logins.field("website") }, set: { logins.setField("website", $0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                confirm("website", "Done: contact-form emails go to the Gmail above")
            }
        case .social: SocialControls()
        case .directories: DirectoryControls()
        case .freshbooks: FreshBooksControls()
        case .bank, .paypal, .venmo: statementControls(id)
        case .claude: ClaudeControls()
        case .github: GitHubControls()
        case .homeServer: EmptyView()
        }
    }

    private func confirm(_ key: String, _ text: String) -> some View {
        Toggle(isOn: Binding(get: { logins.isConfirmed(key) }, set: { logins.setConfirmed(key, $0) })) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text)
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var calendarControls: some View {
        if logins.googleCalendarReady {
            Text(logins.googleCalendarNames.prefix(6).joined(separator: " · ") + (logins.googleCalendarNames.count > 6 ? " …" : ""))
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
        } else if logins.googleNeedsNewSignIn {
            Text("Sign in with Google again (above) to add your Calendar.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        } else {
            macCalendarControls
        }
    }

    @ViewBuilder
    private var macCalendarControls: some View {
        switch logins.calendarAccess {
        case .fullAccess:
            Text(logins.calendarNames.prefix(6).joined(separator: " · ") + (logins.calendarNames.count > 6 ? " …" : ""))
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
        case .denied, .restricted:
            Button("Open Privacy settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            .buttonStyle(SecondaryButtonStyle())
        default:
            Button("Allow calendar access") { Task { await logins.requestCalendar() } }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private var driveControls: some View {
        let accounts = logins.driveAccounts
        if accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !logins.otherDriveAccounts.isEmpty {
                    Text("Ignoring \(logins.otherDriveAccounts.joined(separator: ", ")): not your account. Sign Drive for desktop in as \(logins.ownerEmail) on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Button("Download Google Drive for desktop") {
                    NSWorkspace.shared.open(URL(string: "https://www.google.com/drive/download/")!)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(accounts, id: \.email) { account in
                    HStack {
                        Text(account.email).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Button("Show in Finder") { NSWorkspace.shared.open(account.url) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                Text("Project folders are created here and shared from Drive.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func statementControls(_ id: LoginID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if id == .bank {
                TextField("Your bank's website, e.g. chase.com", text: Binding(get: { logins.field("bankWebsite") }, set: { logins.setField("bankWebsite", $0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
            }
            HStack(spacing: 10) {
                Button(logins.lastImport(id) == nil ? "Log in and get transactions" : "Log in and update") {
                    navigator.bankLogin = id
                }
                .buttonStyle(PrimaryButtonStyle())
                if let last = logins.lastImport(id) {
                    Text("Last updated \(last.formatted(.dateTime.month().day()))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                Text("Keep copies of statements in:").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text((logins.state.statementsFolder ?? BankSite.defaultFolder.path).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                Button("Change") { logins.chooseStatementsFolder() }.buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    // MARK: What each log-in is for

    struct Info {
        let name: String
        let icon: String
        let covers: String
        let gets: [String]
        let never: String
        let steps: [String]
    }

    static let info: [LoginID: Info] = [
        .freshbooks: Info(
            name: "FreshBooks", icon: "doc.text.fill",
            covers: "Your invoices and estimates, kept up to date in Lens",
            gets: ["Every invoice: unpaid ones show as money owed in Money and on the project, and they're marked paid when FreshBooks says so",
                   "Every estimate goes into Past quotes, with whether it was accepted",
                   "Checked every hour"],
            never: "Read only: Lens never creates, changes or sends anything in FreshBooks.",
            steps: ["One-time setup: make a small private app in FreshBooks. Click **Get help** and Claude walks you through it, one click at a time.",
                    "Paste its two keys below, click **Connect FreshBooks** and press **Allow**.",
                    "The page after Allow won't load. That's expected: copy its address from the top of the browser and paste it below."]),
        .google: Info(
            name: "Google (Gmail, Drive, Sheets, Docs, Calendar)", icon: "envelope.fill",
            covers: "Inquiries, client threads, Zoom summaries, payment emails, project folders, your calendar",
            gets: ["Reads your email to find inquiries and attach client threads to projects",
                   "Writes reply drafts you review and send yourself",
                   "Creates shared project folders and documents (only touches files Lens made)",
                   "Reads the intake form's answer sheet",
                   "Reads your Google Calendar to spot clashes and suggest times"],
            never: "Never sends email on its own, never deletes mail, never changes your calendar, never sees your password.",
            steps: ["Click **Sign in with Google** and sign in with your account."]),
        .calendar: Info(
            name: "Calendar", icon: "calendar",
            covers: "Shoots, calls and milestones, plus clash checks when proposing dates",
            gets: ["Sees your events to spot clashes and suggest call times",
                   "Adds shoot days and milestones when a deal is won"],
            never: "Never deletes or changes events it didn't create.",
            steps: ["Sign in with Google above. Your Google Calendar comes with it.",
                    "Only if you don't use Google Calendar: click **Allow calendar access** below to use the Mac's Calendar app instead."]),
        .drive: Info(
            name: "Google Drive for desktop", icon: "externaldrive.fill.badge.icloud",
            covers: "Where shared project folders and statements live",
            gets: ["A Drive folder on the Mac where Lens builds each project's folder from a template"],
            never: "Never deletes anything in Drive.",
            steps: ["Install **Google Drive for desktop** and sign in with your account.",
                    "Leave it running; Lens finds it on its own."]),
        .zoom: Info(
            name: "Zoom (calls + AI Companion)", icon: "phone.fill",
            covers: "Every call's full summary attached to the right inquiry or project",
            gets: ["Every AI Companion summary in your Zoom account, old and new, in full: overview, each topic, next steps and who was there",
                   "Each one placed on the matching inquiry or project, by the client's name and email",
                   "Ask Lens can read and search them all, so you can ask what someone said on a call"],
            never: "Never sees your Zoom password, never changes or deletes anything in Zoom, never joins your calls.",
            steps: ["Click **Connect Zoom** below, sign in to Zoom and press **Allow**.",
                    "That's it. Lens reads all your summaries in the background, then checks for new ones every hour.",
                    "Make sure **Meeting summary** is on in Zoom's AI setting (link below), so every call gets one."]),
        .website: Info(
            name: "Website contact form", icon: "globe",
            covers: "Form inquiries land in the pipeline on their own",
            gets: ["Each form email becomes a new inquiry with a drafted reply and intake link"],
            never: "No website login needed.",
            steps: ["In your website builder (Squarespace, Wix, Showit…), set the contact form to email the Gmail connected above.",
                    "Send yourself a test inquiry once Google is connected."]),
        .social: Info(
            name: "Instagram + Facebook", icon: "camera.aperture",
            covers: "Your DMs and Page messages, with real inquiries sent to Pipeline",
            gets: ["Every Instagram DM and Facebook Page message, checked every hour",
                   "Real inquiries show up on Pipeline, ready to add, tagged Instagram or Facebook",
                   "Everyone who messages you goes in People"],
            never: "Read only: Lens never sends, deletes or marks a message as read. Your passwords stay with Meta.",
            steps: ["Meta makes this a one-time setup: a small private app on your own account. Click **Get help** below and Claude walks you through it, one click at a time.",
                    "At the end you paste two codes below, one for Instagram and one for Facebook. That's it."]),
        .directories: Info(
            name: "Directories + reviews", icon: "list.star",
            covers: "Leads from The Knot, WeddingWire, Thumbtack, Google and more, plus your Google reviews",
            gets: ["Every lead email from these sites becomes an inquiry, tagged with where it came from",
                   "Your Google reviews, listed below as they come in",
                   "Win rate and revenue by source in Money"],
            never: "No logins needed. Lens only reads the emails these sites already send you.",
            steps: ["Nothing to set up. Once Google is connected, Lens finds these emails by itself.",
                    "For Google reviews: in your Google Business Profile, open **Settings**, then **Notifications**, and make sure **Customer reviews** emails are on."]),
        .bank: Info(
            name: "Bank + credit card", icon: "building.columns.fill",
            covers: "Income, expenses and balances for the Money tab",
            gets: ["Checking and credit card transactions, straight into Money",
                   "Deposit and payment alert emails, once Google is connected"],
            never: "Lens never sees or saves your password. You log in on the bank's own page; Lens only reads the statements you download.",
            steps: ["Type your bank's website below and tap **Log in and get transactions**.",
                    "Log in like normal (including the text-message code).",
                    "Find Statements or Download transactions, pick **CSV**, and download. Lens adds it to Money and skips anything already there.",
                    "Do it again whenever you want fresh numbers. The bank may ask you to log in again each time."]),
        .paypal: Info(
            name: "PayPal", icon: "p.circle.fill",
            covers: "Client payments and fees",
            gets: ["Payment received emails (already in Gmail)", "Activity downloads, straight into Money"],
            never: "Lens never sees or saves your password. You log in on PayPal's own page.",
            steps: ["Tap **Log in and get transactions** and log in like normal.",
                    "Tap **Go to statements**, pick CSV and the dates, and download. Lens adds it to Money.",
                    "Keep payment notification emails on."]),
        .venmo: Info(
            name: "Venmo", icon: "v.circle.fill",
            covers: "Deposits paid by Venmo, like Hartley's",
            gets: ["Payment emails (already in Gmail)", "Statements, straight into Money"],
            never: "Lens never sees or saves your password. You log in on Venmo's own page.",
            steps: ["Tap **Log in and get transactions** and log in like normal.",
                    "Tap **Go to statements** and download the CSV. Lens adds it to Money.",
                    "Keep payment email notifications on."]),
        .claude: Info(
            name: "Claude (Ask Lens)", icon: "sparkles",
            covers: "The assistant built into Lens: questions, drafts, changes you approve",
            gets: ["Answers from Lens's own data: deals, projects, rates",
                   "Proposes changes (new inquiries, discovery answers, follow-ups, rates) that wait for your Approve tap",
                   "Remembers how you like to work, in a list you can edit"],
            never: "Never sends email, never moves money, never changes anything you haven't approved.",
            steps: ["Sign up at [console.anthropic.com](https://console.anthropic.com) (use the business email).",
                    "Under **Billing**, add a card and set a **monthly spend limit** (around $100 is plenty to start).",
                    "Under **API Keys**, click **Create Key**, name it Lens, and copy it.",
                    "Paste it below and click **Save**, then **Test**."]),
        .github: Info(
            name: "GitHub (feature ideas)", icon: "lightbulb.fill",
            covers: "When you ask Lens for a new feature, it lands straight in the developer's to-do list",
            gets: ["Can open new Issues on Lens's private repo, and nothing else"],
            never: "Can't see or change any code, and can't touch any other repo.",
            steps: ["Developer: on GitHub, go to [Settings → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).",
                    "Repository access: **Only select repositories → 1047ventures/lens**. Permissions: **Issues → Read and write**. Nothing else.",
                    "Generate it, paste it below on this Mac, and Save. Until then, requests open an email to the developer instead."]),
        .homeServer: Info(
            name: "Home server", icon: "server.rack",
            covers: "Local AI, storage, and the phone sidekick",
            gets: ["Call transcription, drafted replies and proposals, footage tagging"],
            never: "",
            steps: ["Nothing yet. This switches on once the server is built."]),
    ]
}

/// Connect Zoom, and how many summaries Lens has read. Without Zoom connected, Lens falls back to
/// the summary emails in Gmail (ZoomCheck).
private struct ZoomControls: View {
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var zoom: ZoomNotes
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if logins.zoomConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                    Text("Connected · \(logins.zoomReport ?? "Reading your summaries")")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
                if let email = logins.state.zoomEmail {
                    Text(email).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if zoom.myNotesCount > 0 {
                    Text("\(zoom.myNotesCount) call\(zoom.myNotesCount == 1 ? "" : "s") from My Notes read")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if let problem = zoom.myNotesProblem {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        Button("Get help") { ask("Lens showed: \"\(problem)\". How do I add the My Notes permissions to my Lens app in Zoom?") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let progress = zoom.progress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                } else if !zoom.backfillDone && zoom.zoomCount > 0 {
                    Text("Older summaries are still on their way. Lens keeps going in the background.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    Button("Check now") { Task { await zoom.check() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(zoom.checking)
                    Button("Disconnect") { Task { await logins.disconnectZoom() } }
                        .buttonStyle(SecondaryButtonStyle())
                    settingLink
                }
                if let problem = zoom.problem {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        Button("Get help") { ask("Lens is connected to Zoom but showed: \"\(problem)\". What should I do?") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else {
                if logins.hasZoomClient {
                    HStack(spacing: 10) {
                        Button(logins.zoomBusy ? "Waiting for Zoom…" : "Connect Zoom") {
                            Task { await logins.connectZoom() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(logins.zoomBusy)
                        settingLink
                    }
                } else {
                    Text("Connecting Zoom isn't set up on this Mac yet. Ask Claude to set up Zoom for Lens.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Get help") { ask("Connecting Zoom isn't set up on this Mac yet. How do I set up Zoom for Lens?") }
                            .buttonStyle(SecondaryButtonStyle())
                        settingLink
                    }
                }
                if let error = logins.zoomError {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral).fixedSize(horizontal: false, vertical: true)
                        Button("Get help") { ask(logins.zoomHelpQuestion) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                Text("Until Zoom is connected, Lens reads the summary emails Zoom sends to your Gmail.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 4)
                ZoomCheck()
            }
        }
        .onAppear { logins.importZoomClient() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            logins.importZoomClient()
        }
    }

    private var settingLink: some View {
        Link(destination: URL(string: "https://zoom.us/profile/setting?tab=zoomai")!) {
            Label("Zoom's AI summary setting", systemImage: "arrow.up.right.square")
        }
        .font(.system(size: 12))
    }

    private func ask(_ question: String) {
        navigator.askDraft = question
        navigator.askOpen = true
    }
}

/// One button. The Google client arrives on its own (Claude puts it on this Mac), so the user never sees setup.
private struct GoogleControls: View {
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var history: EmailHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if logins.googleConnected {
                HStack(spacing: 14) {
                    ForEach(logins.googleCovers, id: \.name) { item in
                        Text("\(item.name) \(item.on ? "✓" : "–")")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.on ? Theme.teal : Theme.muted)
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                    Text(logins.state.googleEmail ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Button("Disconnect") { Task { await logins.disconnectGoogle() } }.buttonStyle(SecondaryButtonStyle())
                    Button("Start Google over") { Task { await logins.startGoogleOver() } }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .help("Forgets Lens's saved Google setup and sign-in, so a new Google file can be used.")
                }
                if let progress = history.progress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                } else if history.workCount > 0 {
                    Text("\(history.workCount) work conversations summarized" + (history.done ? "" : ", more on the way"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if logins.googleNeedsNewSignIn {
                    Text("Lens now also reads Google Calendar. Sign in once more to allow it.")
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                    signInButton("Sign in with Google again")
                }
            } else if logins.hasGoogleClient {
                Text("Google will warn that it hasn't checked Lens. Click Advanced, then Go to Lens.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack(spacing: 10) {
                    signInButton("Sign in with Google")
                    Button("Start Google over") { Task { await logins.startGoogleOver() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Forgets Lens's saved Google setup, so a new Google file can be used.")
                }
            } else {
                Text("Google sign-in isn't set up on this Mac yet. Ask Claude to set up Google for Lens.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                Button("Get help") { ask("Google sign-in isn't set up on this Mac yet. Please set up Google for Lens.") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let error = logins.googleError {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral).fixedSize(horizontal: false, vertical: true)
                    Button("Get help") { ask(logins.googleHelpQuestion) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func signInButton(_ title: String) -> some View {
        Button(logins.googleBusy ? "Waiting for Google…" : title) {
            Task { await logins.signInWithGoogle() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(logins.googleBusy)
    }

    private func ask(_ question: String) {
        navigator.askDraft = question
        navigator.askOpen = true
    }
}


private struct ClaudeControls: View {
    @EnvironmentObject private var ai: LensAI
    @State private var key = ""
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SecureField(ai.hasKey ? "Key saved · paste a new one to replace it" : "sk-ant-…", text: $key)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
                Button("Save") { ai.saveKey(key); key = ""; result = nil }
                    .buttonStyle(SecondaryButtonStyle()).disabled(key.isEmpty)
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    Task {
                        let error = await ai.testKey()
                        result = error ?? "Works. Ask Lens is ready (⌘K)."
                        testing = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!ai.hasKey || testing)
            }
            if let result {
                Text(result).font(.system(size: 12)).foregroundStyle(result.hasPrefix("Works") ? Theme.teal : Theme.coral)
            }
        }
    }
}

private struct GitHubControls: View {
    @EnvironmentObject private var ai: LensAI
    @State private var token = ""

    var body: some View {
        HStack(spacing: 10) {
            SecureField(ai.hasGitHub ? "Token saved · paste a new one to replace it" : "github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            Button("Save") { ai.saveGitHubToken(token); token = "" }
                .buttonStyle(SecondaryButtonStyle()).disabled(token.isEmpty)
        }
    }
}

/// FreshBooks: two keys from Emma's FreshBooks app, Allow, then paste the address of the page that doesn't load.
private struct FreshBooksControls: View {
    @EnvironmentObject private var freshbooks: FreshBooksSync
    @EnvironmentObject private var navigator: Navigator
    @State private var clientID = ""
    @State private var secret = ""
    @State private var pasted = ""
    @State private var waitingForAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if freshbooks.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                    Text("Connected · \(freshbooks.businessName ?? "FreshBooks")").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
                if let report = freshbooks.report {
                    Text(report).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 10) {
                    Button(freshbooks.busy ? "Checking…" : "Check now") { Task { await freshbooks.sync() } }
                        .buttonStyle(SecondaryButtonStyle()).disabled(freshbooks.busy)
                    Button("Disconnect") { freshbooks.disconnect() }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                if !freshbooks.hasKeys {
                    HStack(spacing: 8) {
                        TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        SecureField("Client Secret", text: $secret).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Button("Save keys") { freshbooks.saveKeys(id: clientID, secret: secret); clientID = ""; secret = "" }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(clientID.isEmpty || secret.isEmpty)
                    }
                }
                HStack(spacing: 10) {
                    Button("Connect FreshBooks") { freshbooks.openAllowPage(); waitingForAddress = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!freshbooks.hasKeys)
                    Button("Get help") {
                        navigator.askDraft = "Walk me through connecting FreshBooks to Lens, one click at a time."
                        navigator.askOpen = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if waitingForAddress {
                    Text("After you press Allow, the page won't load. Copy its address from the top of the browser and paste it here:")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("https://localhost:8765/freshbooks?code=…", text: $pasted).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                        Button(freshbooks.busy ? "Connecting…" : "Finish") {
                            Task { await freshbooks.finish(pasted: pasted); if freshbooks.isConnected { pasted = ""; waitingForAddress = false } }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(pasted.isEmpty || freshbooks.busy)
                    }
                }
            }
            if let problem = freshbooks.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Instagram and Facebook: paste the two codes from Emma's Meta app once, then Lens reads her messages hourly.
private struct SocialControls: View {
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var navigator: Navigator
    @State private var drafts: [String: String] = [:]
    @State private var errors: [String: String] = [:]
    @State private var busy: String?
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if MetaMessages.isConnected(.facebook) && !MetaMessages.isConnected(.instagram) {
                // One Page code covers both when Instagram is linked to the Page.
                row(.facebook)
                Text("Instagram DMs come in through your Facebook Page, as long as your Instagram is linked to it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if let why = UserDefaults.standard.string(forKey: "meta.instagramProblem") {
                    Text(why).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                ForEach(MetaMessages.Site.allCases, id: \.rawValue) { site in
                    row(site)
                }
            }
            HStack(spacing: 10) {
                if MetaMessages.Site.allCases.contains(where: MetaMessages.isConnected) {
                    Button("Check messages now") { Task { await gmail.checkSocial() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Button("Get help") {
                    navigator.askDraft = "Walk me through connecting Instagram and Facebook messages to Lens, one click at a time. Both are professional accounts."
                    navigator.askOpen = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if let problem = gmail.socialProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            } else if let checked = gmail.socialChecked {
                Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .id(refresh)
    }

    @ViewBuilder
    private func row(_ site: MetaMessages.Site) -> some View {
        if MetaMessages.isConnected(site) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                Text("\(site.rawValue) connected" + (MetaMessages.accountName(site).map { " · \($0)" } ?? ""))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Button("Disconnect") { MetaMessages.disconnect(site); refresh += 1 }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField(site == .instagram ? "Paste your Instagram code" : "Paste your Facebook Page code",
                                text: Binding(get: { drafts[site.rawValue] ?? "" }, set: { drafts[site.rawValue] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Button(busy == site.rawValue ? "Checking…" : "Connect \(site.rawValue)") {
                        Task { await connect(site) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy != nil || (drafts[site.rawValue] ?? "").isEmpty)
                }
                if let error = errors[site.rawValue] {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func connect(_ site: MetaMessages.Site) async {
        busy = site.rawValue
        defer { busy = nil }
        do {
            _ = try await MetaMessages.connect(site, token: drafts[site.rawValue] ?? "")
            drafts[site.rawValue] = nil
            errors[site.rawValue] = nil
            refresh += 1
            await gmail.checkSocial()
        } catch {
            errors[site.rawValue] = (error as? LocalizedError)?.errorDescription ?? "That code didn't work. Make a new one and try again."
        }
    }
}

/// Directories and Google reviews: nothing to set up, Lens reads the emails these sites send.
private struct DirectoryControls: View {
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var deals: DealStore

    private static let sources = ["The Knot", "WeddingWire", "Thumbtack", "Zola", "Yelp", "Google"]

    var body: some View {
        let seen = Set(deals.deals.map(\.source) + gmail.suggestions.map(\.source))
        let found = Self.sources.filter(seen.contains)
        VStack(alignment: .leading, spacing: 10) {
            Text(found.isEmpty ? "No leads from these sites yet. They'll show up on Pipeline as soon as one emails you."
                               : "Leads found from: " + found.joined(separator: ", "))
                .font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if gmail.reviews.isEmpty {
                Text("No Google review emails yet. Turn on review emails in your Google Business Profile (steps on the left).")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your Google reviews").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                ForEach(gmail.reviews.prefix(5)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(r.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        if !r.snippet.isEmpty {
                            Text(r.snippet).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(2)
                        }
                        if let url = URL(string: r.link) {
                            Link("Open ↗", destination: url).font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }
}
