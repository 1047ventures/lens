import SwiftUI
import AppKit

/// The quotes and proposals on one project or deal, with an Upload button. Uploaded files are read by
/// Claude so the price and what it covered go into Emma's quote history.
struct QuotesPanel: View {
    var projectID: UUID?
    var dealID: UUID?
    var client: String
    @EnvironmentObject private var quotes: QuoteStore
    @EnvironmentObject private var ai: LensAI
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore

    private var list: [Quote] {
        quotes.quotes.filter { q in
            (projectID != nil && q.projectID == projectID) || (dealID != nil && q.dealID == dealID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Proposals and quotes · \(list.count)")
            if list.isEmpty {
                Text("Upload the proposal or quote you sent. Lens keeps the file here, reads the price and what it covered, and remembers it for pricing future jobs.")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list) { q in QuoteRow(quote: q) }
            HStack(spacing: 10) {
                Button("Upload a proposal or quote…") {
                    quotes.upload(projectID: projectID, dealID: dealID, client: client, ai: ai, projects: projects, deals: deals)
                }
                .buttonStyle(PrimaryButtonStyle())
                if let reading = quotes.reading {
                    ProgressView().controlSize(.small)
                    Text(reading).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            if let problem = quotes.problem {
                Text(problem).font(Theme.font(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel(padding: 22)
    }
}

/// One quote: who, when, how much, and whether it went ahead.
struct QuoteRow: View {
    let quote: Quote
    var showClient = false
    @EnvironmentObject private var quotes: QuoteStore
    @EnvironmentObject private var ai: LensAI
    @State private var confirmRemove = false
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !quote.packages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(quote.packages, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: quote.chosen == p.name ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(quote.chosen == p.name ? Theme.teal : Theme.muted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                                if !p.includes.isEmpty {
                                    Text(p.includes).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Text(p.amount.map { Money.string($0) } ?? "").font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                        }
                    }
                    if quote.packages.count > 1 {
                        Menu {
                            ForEach(quote.packages, id: \.self) { p in
                                Button(p.name + (p.amount.map { " · " + Money.string($0) } ?? "")) {
                                    quotes.choose(p.name, in: quote, deals: deals, projects: projects)
                                }
                            }
                        } label: {
                            Text(quote.chosen == nil ? "Which one did they choose?" : "They chose \(quote.chosen ?? "")")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.leading, 30)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: quote.source == "Lens proposal" ? "doc.richtext" : quote.source == "Email" ? "envelope" : "doc.text")
                .foregroundStyle(Theme.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(showClient && !quote.client.isEmpty ? "\(quote.client) · \(quote.title)" : quote.title)
                    .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(details).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            if quote.source == "Lens proposal" {
                Text(quote.amount.map { Money.string($0) } ?? "")
                    .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            } else {
                // Emma can type the price herself, or correct what Lens read.
                TextField("Price", text: Binding(
                    get: { quote.amount.map { String(Int($0.rounded())) } ?? "" },
                    set: { text in
                        let digits = text.filter(\.isNumber)
                        quotes.setPrice(quote, digits.isEmpty ? nil : Double(digits), deals: deals, projects: projects)
                    }))
                    .textFieldStyle(.roundedBorder).frame(width: 84).multilineTextAlignment(.trailing)
                    .help("The price. Type it in if Lens couldn't read it.")
            }
            if quote.source != "Lens proposal" {
                if quote.isFile {
                    Button("Open") { open() }.buttonStyle(SecondaryButtonStyle())
                    Button("Read again") {
                        Task { await quotes.reread(quote, ai: ai, projects: projects, deals: deals) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(quotes.reading != nil)
                }
                Button {
                    if confirmRemove { quotes.remove(quote) } else { confirmRemove = true }
                } label: {
                    if confirmRemove { Text("Remove?").font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.coral) }
                    else { Image(systemName: "trash").foregroundStyle(Theme.muted) }
                }
                .buttonStyle(.plain)
                .help("Remove this quote from Lens. Your file isn't touched.")
                Menu {
                    ForEach(["Sent", "Accepted", "Declined"], id: \.self) { s in
                        Button(s) { var q = quote; q.status = s; quotes.update(q) }
                    }
                    if !quote.location.isEmpty {
                        Button("Open") { open() }
                    }
                    Button("Remove from history") { quotes.remove(quote) }
                } label: {
                    Text(quote.status.isEmpty ? "Status" : quote.status)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else if !quote.status.isEmpty {
                Text(quote.status).font(Theme.font(size: 12)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        var parts = [quote.date.formatted(date: .abbreviated, time: .omitted)]
        if !quote.kind.isEmpty { parts.append(quote.kind) }
        if let days = quote.shootDays { parts.append(days == 1 ? "1 shoot day" : "\(days.formatted()) shoot days") }
        if !quote.deliverables.isEmpty { parts.append(quote.deliverables) }
        return parts.joined(separator: " · ")
    }

    private func open() {
        let url = quote.location.lowercased().hasPrefix("http") ? URL(string: quote.location) : URL(fileURLWithPath: quote.location)
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// Everything Emma has quoted, to look back on and to price new work from.
struct QuoteHistoryView: View {
    @EnvironmentObject private var quotes: QuoteStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var list: [Quote] {
        let all = quotes.history(deals: deals)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { [$0.client, $0.title, $0.kind, $0.deliverables].joined(separator: " ").lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Past quotes").font(Theme.font(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
            summary
            TextField("Search by client, kind of work or deliverable", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if list.isEmpty {
                        Text("No quotes yet. Upload past proposals on a project or deal, and Lens also finds the ones you sent by email.")
                            .font(Theme.font(size: 13)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(list) { q in QuoteRow(quote: q, showClient: true) }
                }
            }
            HStack(spacing: 10) {
                Button("Help me price a new job") {
                    dismiss()
                    navigator.askDraft = "Help me price a new job. Ask me what it is, then compare it with my past quotes and suggest a price."
                    navigator.askOpen = true
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("Ask Lens compares it with what you charged before.").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 520)
        .background(Theme.ground)
    }

    @ViewBuilder private var summary: some View {
        let priced = list.filter { $0.amount != nil }
        let accepted = priced.filter { $0.status == "Accepted" }
        let decided = priced.filter { $0.status == "Accepted" || $0.status == "Declined" }
        HStack(spacing: 28) {
            figure("Quotes", "\(list.count)")
            if !priced.isEmpty {
                figure("Average quote", Money.string(priced.compactMap(\.amount).reduce(0, +) / Double(priced.count)))
            }
            if !accepted.isEmpty {
                figure("Average accepted", Money.string(accepted.compactMap(\.amount).reduce(0, +) / Double(accepted.count)))
            }
            if !decided.isEmpty {
                figure("Accepted", "\(Int((Double(accepted.count) / Double(decided.count) * 100).rounded()))%")
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.font(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
        }
    }
}
