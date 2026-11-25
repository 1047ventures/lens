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
    /// The card showing. Swiping, scrolling, the arrows, the arrow keys and the dashes all move it.
    @State private var current: Int? = 0

    private var index: Int { min(max(current ?? 0, 0), items.count - 1) }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            // One card per page, side by side: swipe or scroll sideways on a trackpad or mouse.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        page(i)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                top
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36).padding(.top, 24)

            HStack {
                arrow("chevron.left", show: index > 0) { go(index - 1) }
                Spacer()
                arrow("chevron.right", show: true) { next() }
            }
            .padding(.horizontal, 16)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { next(); return .handled }
        .onKeyPress(.leftArrow) { go(index - 1); return .handled }
        .onKeyPress(.space) { next(); return .handled }
        .onExitCommand { done() }
    }

    private func go(_ i: Int) {
        guard items.indices.contains(i) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { current = i }
    }

    /// The next card, or Home after the last one.
    private func next() {
        if index + 1 < items.count { go(index + 1) } else { done() }
    }

    private func tint(_ item: TodayItem) -> Color {
        switch item.tone {
        case .overdue: return Theme.coral
        case .soon: return Palette.violet
        case .neutral: return Theme.teal
        }
    }

    private func page(_ i: Int) -> some View {
        let item = items[i]
        let project = projects.project(id: item.projectID)
        return ZStack(alignment: .bottomLeading) {
            ZStack {
                if let project {
                    ProjectCoverView(project: project)
                    Color.black.opacity(0.2)
                } else {
                    LinearGradient(colors: [tint(item).opacity(0.85), Theme.ground], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            }
            .background(Theme.ground)
            // Click the picture to see the next card.
            .contentShape(Rectangle())
            .onTapGesture { next() }

            content(item, isLast: i == items.count - 1)
                .padding(.horizontal, 72).padding(.bottom, 56)
        }
        .clipped()
    }

    private var top: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(0..<items.count, id: \.self) { i in
                    Button { go(i) } label: {
                        Capsule().fill(.white.opacity(i <= index ? 0.95 : 0.3)).frame(height: 4)
                            .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Card \(i + 1)")
                }
            }
            HStack {
                Text("\(index + 1) of \(items.count)")
                    .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button(action: done) {
                    Text("Skip to Home")
                        .font(Theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.black.opacity(0.3)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func arrow(_ icon: String, show: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.3))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.25)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(show ? 1 : 0)
        .disabled(!show)
    }

    private func content(_ item: TodayItem, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.kicker.uppercased())
                .font(Theme.font(size: 12, weight: .bold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.85))
            Text(item.title)
                .font(Theme.display(size: 42))
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
                Button { next() } label: {
                    Text(isLast ? "On to my day" : "Later").font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(.white.opacity(0.18)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}
