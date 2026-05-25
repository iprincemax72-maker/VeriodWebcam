import SwiftUI

@main
struct VeriodWebcamApp: App {
    var body: some Scene {
        WindowGroup("VeriodWebcam") {
            ContentView()
                .frame(minWidth: 520, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}
