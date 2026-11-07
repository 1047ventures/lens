import SwiftUI
import AppKit

/// The Ask Lens panel (⌘K): a conversation with Claude that can look things up across Lens,
/// propose changes Emma approves with one tap, and learn how she likes to work.
struct AskLensView: View {
    @EnvironmentObject private var ai: LensAI
    @EnvironmentObject private var navigator: Navigator
    @State private var draft = ""
    @State private var showLearned = false
    @FocusState private var focused: Bool

    private let suggestions = [
        "What needs my attention this week?",
        "Turn this DM into an inquiry: ",
        "Draft a follow-up for the CEJ proposal",
        "What do I clear per hour on each CEJ option?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if showLearned {
                learned
            } else {
                conversation
            }
            Divider().overlay(Theme.line)
            composer
        }
        .background(Theme.ground)
        .onAppear { focused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Palette.violet)
            Text("Ask Lens").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Button(showLearned ? "Chat" : "Learned · \(ai.notes.count)") { showLearned.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Button {
                ai.newConversation()
                showLearned = false
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text3)
            .help("New conversation")
            .disabled(ai.busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if ai.items.isEmpty {
                        intro
                    }
                    ForEach(ai.items) { item in
                        row(item).id(item.id)
                    }
                    if ai.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .id("busy")
                    }
                }
                .padding(16)
            }
            .onChange(of: ai.items.count) { _, _ in
                withAnimation { proxy.scrollTo(ai.items.last?.id, anchor: .bottom) }
            }
            .onChange(of: ai.busy) { _, busy in
                if busy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about anything in Lens, paste in a message, or tell it how you like to work. It asks before changing anything.")
                .font(.system(size: 13)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { s in
                Button {
                    if s.hasSuffix(": ") { draft = s; focused = true }
                    else { Task { await ai.send(s) } }
                } label: {
                    Text(s).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        .foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain)
                .disabled(!ai.hasKey)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: LensAI.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .padding(10)
                    .background(Palette.violet.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(markdown(item.text)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .action:
            if let action = item.action { actionCard(action) }
        case .draft:
            if let d = item.draft { draftCard(d) }
        case .info:
            Text(item.text).font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.coral)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionCard(_ action: LensAI.Action) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action.summary).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            switch action.state {
            case .waiting:
                HStack(spacing: 8) {
                    Button("Approve") { ai.decide(action.id, approve: true) }.buttonStyle(PrimaryButtonStyle())
                    Button("Skip") { ai.decide(action.id, approve: false) }.buttonStyle(SecondaryButtonStyle())
                }
            case .approved:
                Label("Approved", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.teal)
            case .skipped:
                Label("Skipped", systemImage: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .accentBar(action.state == .waiting ? Theme.amber : Theme.line, cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func draftCard(_ d: LensAI.Draft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorLabel("Draft email", Palette.blue)
                Spacer()
            }
            if !d.to.isEmpty { Text("To: \(d.to)").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            Text(d.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Text(d.body).font(.system(size: 13)).foregroundStyle(Theme.text2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(d.subject)\n\n\(d.body)", forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Open in Mail") {
                    var c = URLComponents()
                    c.scheme = "mailto"
                    c.path = d.to
                    c.queryItems = [URLQueryItem(name: "subject", value: d.subject), URLQueryItem(name: "body", value: d.body)]
                    if let url = c.url { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .accentBar(Palette.blue, cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    // MARK: Learned

    private var learned: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ColorLabel("What Lens has learned", Palette.violet)
                Text("Lens follows these in every conversation. Tell it \"remember that…\" to add one, or edit and delete them here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if ai.notes.isEmpty {
                    Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                ForEach(ai.notes) { note in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("", text: Binding(get: { note.text }, set: { ai.editNote(note, text: $0) }), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                        Button { ai.forget(note) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Forget this")
                    }
                    .padding(10)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !ai.requests.isEmpty {
                    ColorLabel("Change requests sent to Sean", Palette.gold).padding(.top, 10)
                    ForEach(ai.requests.reversed()) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            HStack {
                                Text(r.created.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                if let link = r.link, let url = URL(string: link) {
                                    Link("View on GitHub ↗", destination: url).font(.system(size: 11))
                                } else {
                                    Text("sent by email").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ai.hasKey {
                Button {
                    navigator.open(.logins)
                } label: {
                    Label("Connect Claude in Log-ins to start", systemImage: "key.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.amber)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Lens…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(10)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Palette.violet : Theme.track)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            Text(ai.monthSpend > 0 ? "About \(String(format: "$%.2f", ai.monthSpend)) used this month" : "Uses Claude Opus 5.5 · charged to the connected Anthropic account")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(12)
    }

    private var canSend: Bool { ai.hasKey && !ai.busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await ai.send(text) }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
