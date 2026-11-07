import SwiftUI

/// Every account Lens needs, what it gets from each, and the exact steps to connect it.
/// Lens never sees or stores passwords: each connection uses the service's own sign-in,
/// a Mac permission prompt, or something Emma already has (like email notifications).
struct LoginsView: View {
    @EnvironmentObject private var logins: ConnectionStore
    @State private var expanded: Set<LoginID> = []

    private struct Group: Identifiable {
        let id: String
        let color: Color
        let note: String
        let items: [LoginID]
    }

    private let groups = [
        Group(id: "Google account", color: Palette.blue, note: "One sign-in covers most of what Lens reads.", items: [.google, .calendar, .drive]),
        Group(id: "Calls", color: Palette.violet, note: "Zoom already records and summarizes her calls.", items: [.zoom]),
        Group(id: "Where clients find her", color: Palette.orchid, note: "Every way a new inquiry can arrive.", items: [.website, .social, .directories]),
        Group(id: "Money", color: Palette.lime, note: "Read-only. Lens can't move a cent.", items: [.bank, .paypal, .venmo]),
        Group(id: "Lens itself", color: Palette.violet, note: "Ask Lens, and sending ideas to Sean.", items: [.claude, .github]),
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
        .onAppear { logins.refreshCalendar() }
    }

    private var header: some View {
        let p = logins.progress
        return VStack(alignment: .leading, spacing: 12) {
            Text("Log-ins").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
            Text("Everything Lens needs to see the whole business. Lens never sees or stores passwords: each one opens the service's own sign-in, or uses something Emma already has.")
                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Emma's Google account").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                TextField(ConnectionStore.defaultOwnerEmail, text: Binding(get: { logins.field("ownerEmail") }, set: { logins.setField("ownerEmail", $0) }))
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
                        Text("EMMA DOES").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(color)
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
        case .zoom: confirm("zoom", "Done: her AI summaries get emailed to the Gmail above")
        case .website:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Her website, e.g. emmapionberlin.com", text: Binding(get: { logins.field("website") }, set: { logins.setField("website", $0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                confirm("website", "Done: contact-form emails go to the Gmail above")
            }
        case .social: confirm("social", "Done: switched to a professional account")
        case .directories: directoryControls
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
                    Text("Ignoring \(logins.otherDriveAccounts.joined(separator: ", ")): not Emma's account. Sign Drive for desktop in as \(logins.ownerEmail) on her Mac.")
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

    private static let directoryOptions = ["The Knot", "WeddingWire", "Google Business Profile", "Thumbtack", "Yelp", "Zola"]

    private var directoryControls: some View {
        let picked = Set(logins.field("directories").split(separator: ",").map(String.init))
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(Self.directoryOptions, id: \.self) { name in
                    let on = picked.contains(name)
                    Button {
                        var next = picked
                        if on { next.remove(name) } else { next.insert(name) }
                        logins.setField("directories", Self.directoryOptions.filter(next.contains).joined(separator: ","))
                    } label: {
                        Text(name).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(on ? Palette.orchid.opacity(0.22) : Theme.raised)
                            .foregroundStyle(on ? Theme.text : Theme.text3)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            confirm("directories", "Done: lead emails from each go to the Gmail above")
        }
    }

    private func statementControls(_ id: LoginID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let folder = logins.state.statementsFolder {
                    Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    Button("Change") { logins.chooseStatementsFolder() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Choose the statements folder") { logins.chooseStatementsFolder() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            if logins.state.statementsFolder != nil {
                confirm(id.rawValue, "Done: first statement saved there")
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
        .google: Info(
            name: "Google (Gmail, Drive, Sheets)", icon: "envelope.fill",
            covers: "Inquiries, client threads, Zoom summaries, payment emails, project folders",
            gets: ["Reads her email to find inquiries and attach client threads to projects",
                   "Writes reply drafts she reviews and sends herself",
                   "Creates shared project folders (only touches files Lens made)",
                   "Reads the intake form's answer sheet"],
            never: "Never sends email on its own, never deletes mail, never sees her password.",
            steps: ["Open the [Google Cloud console](https://console.cloud.google.com/) and create a project called **Lens**.",
                    "Under APIs & Services → Library, turn on the **Gmail API**, **Google Drive API** and **Google Sheets API**.",
                    "Under OAuth consent screen: choose External, name it Lens, add her Gmail as a test user, then set publishing status to **In production** so the sign-in doesn't expire weekly.",
                    "Under Credentials → Create credentials → **OAuth client ID** → Desktop app. Paste the client ID and secret below.",
                    "Click **Sign in with Google** and sign in as Emma. Google will warn the app isn't verified (it's private to you two): Advanced → Go to Lens."]),
        .calendar: Info(
            name: "Calendar", icon: "calendar",
            covers: "Shoots, calls and milestones, plus clash checks when proposing dates",
            gets: ["Sees her events to spot clashes and suggest call times",
                   "Adds shoot days and milestones when a deal is won"],
            never: "Never deletes or changes events it didn't create.",
            steps: ["Make sure her Google Calendar shows in the Mac **Calendar** app (Calendar → Settings → Accounts → add Google).",
                    "Click **Allow calendar access** below and approve the Mac's prompt."]),
        .drive: Info(
            name: "Google Drive for desktop", icon: "externaldrive.fill.badge.icloud",
            covers: "Where shared project folders and statements live",
            gets: ["A Drive folder on the Mac where Lens builds each project's folder from a template"],
            never: "Never deletes anything in Drive.",
            steps: ["Install **Google Drive for desktop** and sign in as Emma.",
                    "Leave it running; Lens finds it on its own."]),
        .zoom: Info(
            name: "Zoom (calls + AI Companion)", icon: "phone.fill",
            covers: "Every call's summary attached to the right inquiry or project",
            gets: ["The AI summary email after each call, matched to the client by name and email",
                   "Discovery answers pulled from first calls into the proposal builder"],
            never: "No Zoom password; it all arrives as email.",
            steps: ["In Zoom on the web: Settings → **AI Companion** → turn on **Meeting summary** and set it to send automatically to the host.",
                    "For Zoom Phone: Settings → Phone → turn on **AI call summaries** emailed to her.",
                    "Make sure those emails go to the Gmail connected above."]),
        .website: Info(
            name: "Website contact form", icon: "globe",
            covers: "Form inquiries land in the pipeline on their own",
            gets: ["Each form email becomes a new inquiry with a drafted reply and intake link"],
            never: "No website login needed.",
            steps: ["In her website builder (Squarespace, Wix, Showit…), set the contact form to email the Gmail connected above.",
                    "Send yourself a test inquiry once Google is connected."]),
        .social: Info(
            name: "Instagram + Facebook", icon: "camera.aperture",
            covers: "DMs and comments from people who find her on social",
            gets: ["Now: \"Paste a DM\" turns a message into an inquiry with a ready-to-copy reply",
                   "Later: a direct link once her account is professional (Meta only allows this for business and creator accounts)"],
            never: "No app can read personal-account DMs, so nothing is read until she connects.",
            steps: ["In Instagram: Settings → Account type and tools → **Switch to professional account** (Creator or Business).",
                    "Link it to her Facebook Page (create a simple one if needed).",
                    "Tick below. Lens adds the direct Meta sign-in in a later phase."]),
        .directories: Info(
            name: "Directories + reviews", icon: "list.star",
            covers: "Leads from wedding sites and Google searches",
            gets: ["Lead emails from each directory, turned into inquiries tagged with where they came from",
                   "Win rate and revenue by source in Money"],
            never: "No directory logins needed.",
            steps: ["Tap each place she's listed.",
                    "In each one's settings, send lead notifications to the Gmail connected above."]),
        .bank: Info(
            name: "Bank + credit card", icon: "building.columns.fill",
            covers: "Income, expenses and balances for the Money tab",
            gets: ["Monthly statements (CSV) from a folder she saves them to",
                   "Deposit and payment alert emails, once Google is connected"],
            never: "No bank password, no access that can move money. A live bank link (Plaid) can come later if wanted.",
            steps: ["Pick a statements folder below (inside Google Drive is handy).",
                    "Once a month, download each account's statement as **CSV** (Download/Export in online banking) into it.",
                    "Optional: turn on deposit and large-purchase email alerts to her Gmail."]),
        .paypal: Info(
            name: "PayPal", icon: "p.circle.fill",
            covers: "Client payments and fees",
            gets: ["Payment received emails (already in Gmail)", "Monthly activity export for the books"],
            never: "No PayPal password.",
            steps: ["In PayPal: Activity → **Download** → CSV for last month, saved into the statements folder.",
                    "Keep payment notification emails on."]),
        .venmo: Info(
            name: "Venmo", icon: "v.circle.fill",
            covers: "Deposits paid by Venmo, like Hartley's",
            gets: ["Payment emails (already in Gmail)", "Monthly statement for the books"],
            never: "Venmo has no app access for personal accounts; nothing reads it directly.",
            steps: ["In the Venmo app or website: Statements → **Download CSV** each month into the statements folder.",
                    "Keep payment email notifications on."]),
        .claude: Info(
            name: "Claude (Ask Lens)", icon: "sparkles",
            covers: "The assistant built into Lens: questions, drafts, changes she approves",
            gets: ["Answers from Lens's own data: deals, projects, rates",
                   "Proposes changes (new inquiries, discovery answers, follow-ups, rates) that wait for her Approve tap",
                   "Remembers how she likes to work, in a list she can edit"],
            never: "Never sends email, never moves money, never changes anything she hasn't approved.",
            steps: ["Sign up at [console.anthropic.com](https://console.anthropic.com) (use the business email).",
                    "Under **Billing**, add a card and set a **monthly spend limit** (around $100 is plenty to start).",
                    "Under **API Keys**, click **Create Key**, name it Lens, and copy it.",
                    "Paste it below and click **Save**, then **Test**."]),
        .github: Info(
            name: "GitHub (ideas for Sean)", icon: "lightbulb.fill",
            covers: "When she asks Lens for a new feature, it lands straight in Sean's to-do list",
            gets: ["Can open new Issues on Lens's private repo, and nothing else"],
            never: "Can't see or change any code, and can't touch any other repo.",
            steps: ["Sean: on GitHub, go to [Settings → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).",
                    "Repository access: **Only select repositories → 1047ventures/lens**. Permissions: **Issues → Read and write**. Nothing else.",
                    "Generate it, paste it below on Emma's Mac, and Save. Until then, requests open an email to Sean instead."]),
        .homeServer: Info(
            name: "Home server", icon: "server.rack",
            covers: "Local AI, storage, and the phone sidekick",
            gets: ["Call transcription, drafted replies and proposals, footage tagging"],
            never: "",
            steps: ["Nothing yet. This switches on once the server is built."]),
    ]
}

/// Google needs a client ID and secret (from her own Google Cloud project) before the sign-in button works.
private struct GoogleControls: View {
    @EnvironmentObject private var logins: ConnectionStore
    @State private var clientID = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if logins.googleConnected {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.teal)
                    Text("Signed in as \(logins.state.googleEmail ?? "")").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Button("Disconnect") { Task { await logins.disconnectGoogle() } }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 10) {
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).frame(width: 260)
                    SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button("Save") { logins.saveGoogleClient(id: clientID, secret: secret) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(clientID.isEmpty || secret.isEmpty)
                }
                HStack(spacing: 12) {
                    Button(logins.googleBusy ? "Waiting for Google…" : "Sign in with Google") {
                        Task { await logins.signInWithGoogle() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!logins.hasGoogleClient || logins.googleBusy)
                    if logins.hasGoogleClient && !logins.googleBusy {
                        Text("Client saved in the Keychain").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                if let error = logins.googleError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                }
            }
        }
        .onAppear { clientID = logins.googleClientID }
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
