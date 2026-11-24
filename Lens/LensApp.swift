import SwiftUI

@main
struct LensApp: App {
    init() { Theme.registerFonts() }

    var body: some Scene {
        WindowGroup("Lens") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await Updater.shared.check() }
                }
            }
        }
    }
}
