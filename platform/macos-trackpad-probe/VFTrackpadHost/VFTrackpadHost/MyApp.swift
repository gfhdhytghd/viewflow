import SwiftUI
import Darwin

@main struct MyApp: App {
    init() {
        if let mode = CommandLine.arguments.dropFirst().first,
           ["--driver-status", "--receive-stdin"].contains(mode) {
            exit(TrackpadBridge.run(mode))
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
