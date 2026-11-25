import SwiftUI

// The first time she opens Lens each day: a handful of full-screen cards, one thing to act on per
// card, then the Projects wall. The things come from `TodayItem.build`, the same list Today shows.

enum MorningCards {
    private static let key = "morning.lastShown"
    static let most = 5

    private static var today: String { Date().formatted(.iso8601.year().month().day()) }

    /// Saved on this Mac: it's about how Lens greets her, not her data.
    static var shownToday: Bool { UserDefaults.standard.string(forKey: key) == today }
    static func markShown() { UserDefaults.standard.set(today, forKey: key) }

    /// What the cards would show now (jobs about drives and log-ins stay on Today).
    @MainActor static func things(viewModel: ScanViewModel, projects: ProjectStore, deals: DealStore,
                                  logins: ConnectionStore, people: PeopleStore, navigator: Navigator) -> [TodayItem] {
        let all = TodayItem.build(viewModel: viewModel, projects: projects, deals: deals, logins: logins, people: people, navigator: navigator)
        return Array(all.filter { !$0.admin }.prefix(most))
    }
}

struct MorningCardsView: View {
    let items: [TodayItem]
    let done: () -> Void
    @EnvironmentObject private var projects: ProjectStore
    @State private var index = 0

    private var item: TodayItem { items[min(index, items.count - 1)] }
    private var project: Project? { projects.project(id: item.projectID) }

    private var tint: Color {
        switch item.tone {
        case .overdue: return Theme.coral
        case .soon: return Palette.violet
        case .neutral: return Theme.teal
        }
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                top
                Spacer(minLength: 0)
                content
            }
            .padding(36)
        }
        .onExitCommand { done() }
    }

    @ViewBuilder private var background: some View {
        ZStack {
            if let project {
                ProjectCoverView(project: project)
                Color.black.opacity(0.25)
            } else {
                LinearGradient(colors: [tint.opacity(0.85), Theme.ground], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
        }
        .background(Theme.ground)
        .ignoresSafeArea()
    }

    private var top: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(0..<items.count, id: \.self) { i in
                    Capsule().fill(.white.opacity(i <= index ? 0.95 : 0.3)).frame(height: 4)
                }
            }
            HStack {
                Text("\(index + 1) of \(items.count)")
                    .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button("Skip all", action: done)
                    .buttonStyle(.plain)
                    .font(Theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.25)).clipShape(Capsule())
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.kicker.uppercased())
                .font(Theme.font(size: 12, weight: .bold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.85))
            Text(item.title)
                .font(Theme.font(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.detail)
                .font(Theme.font(size: 18))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    done()
                    item.action()
                } label: {
                    Text(item.actionTitle).font(Theme.font(size: 15, weight: .bold)).padding(.horizontal, 10)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button {
                    if index + 1 < items.count {
                        index += 1
                    } else {
                        done()
                    }
                } label: {
                    Text("Later").font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(.white.opacity(0.18)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
    }
}
