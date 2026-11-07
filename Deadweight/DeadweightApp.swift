import SwiftUI

@main
struct DeadweightApp: App {
    var body: some Scene {
        WindowGroup("Lens") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)
                .tint(Theme.teal)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
