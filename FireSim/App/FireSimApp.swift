import SwiftUI

@main
struct FireSimApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 860)
        #endif
    }
}
