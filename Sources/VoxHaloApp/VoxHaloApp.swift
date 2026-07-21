import SwiftUI

@main
struct VoxHaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("VoxHalo") {
            Text("VoxHalo")
                .frame(minWidth: 520, minHeight: 360)
        }
    }
}
