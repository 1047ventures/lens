import SwiftUI

/// The one minute tour. A small card walks through each part of Lens while the real screen
/// changes behind it, so the new user sees where things live, not a picture of them.
/// Shows once on first open; "Take the tour" under the version number replays it.
struct TourStop {
    let section: SidebarSection?
    let opensAsk: Bool
    let icon: String
    let title: String
    let body: String
}

enum Tour {
    static let stops: [TourStop] = [
        TourStop(section: .today, opensAsk: false, icon: "hand.wave",
                 title: "Welcome to Lens",
                 body: "Your whole photo and video business in one place. This quick tour shows you where everything lives. It takes about a minute."),
        TourStop(section: .today, opensAsk: false, icon: "sun.max",
                 title: "Today",
                 body: "Start here. It shows what's coming up, who's waiting on you, and the one thing to do next."),
        TourStop(section: .pipeline, opensAsk: false, icon: "line.3.horizontal.decrease",
                 title: "Pipeline",
                 body: "Every inquiry, from first message to booked. Open one to see the price Lens suggests and build a proposal in a few clicks."),
        TourStop(section: .projects, opensAsk: false, icon: "folder",
                 title: "Projects",
                 body: "Each booked shoot gets a project: the date, the client, the files, and what's left to deliver."),
        TourStop(section: .footage, opensAsk: false, icon: "photo.stack",
                 title: "Library",
                 body: "Every photo and video on your drives, your Mac and the Photos app. Lens remembers a drive after you unplug it, so you can still search it. It can pull the photos off an old website too."),
        TourStop(section: .money, opensAsk: false, icon: "dollarsign",
                 title: "Money and Gear",
                 body: "Money adds up what came in, what went out, and what to save for taxes. Log in to your bank, Venmo or PayPal once and Lens fills it in. Gear keeps your kit and what it's worth."),
        TourStop(section: .logins, opensAsk: false, icon: "key",
                 title: "Log-ins",
                 body: "Connect your email, calendar and bank here, one time each. Passwords stay locked on this Mac. Lens only reads, it never pays or posts anything."),
        TourStop(section: nil, opensAsk: true, icon: "sparkles",
                 title: "Ask Lens",
                 body: "Not sure where something is? Ask in plain words, like \"who haven't I replied to?\" or \"what did I make in March?\" Lens checks with you before it changes anything."),
        TourStop(section: .footage, opensAsk: false, icon: "externaldrive",
                 title: "Your first step",
                 body: "Plug in one of your drives. Lens will offer to add it here. It just reads the drive, nothing gets moved or deleted. Then try the search box."),
    ]
}

struct TourCard: View {
    @EnvironmentObject private var navigator: Navigator
    @AppStorage("tourSeen") private var tourSeen = false
    @State private var index = 0

    private var stop: TourStop { Tour.stops[index] }
    private var isLast: Bool { index == Tour.stops.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: stop.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onTeal)
                    .frame(width: 30, height: 30)
                    .background(Theme.teal)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(stop.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button { finish() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Close the tour")
            }
            Text(stop.body)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Where you are in the tour.
                HStack(spacing: 4) {
                    ForEach(Tour.stops.indices, id: \.self) { i in
                        Capsule().fill(i == index ? Theme.teal : Theme.track)
                            .frame(width: i == index ? 14 : 5, height: 5)
                    }
                }
                Spacer()
                if index > 0 {
                    Button("Back") { go(index - 1) }.buttonStyle(SecondaryButtonStyle())
                }
                Button(isLast ? "Got it" : (index == 0 ? "Show me" : "Next")) {
                    isLast ? finish() : go(index + 1)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.teal.opacity(0.45)))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .padding(20)
        .onAppear { go(0) }
    }

    private func go(_ i: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            index = i
            let s = Tour.stops[i]
            navigator.askOpen = s.opensAsk
            if let section = s.section { navigator.open(section) }
        }
    }

    private func finish() {
        tourSeen = true
        navigator.askOpen = false
        withAnimation { navigator.touring = false }
    }
}
