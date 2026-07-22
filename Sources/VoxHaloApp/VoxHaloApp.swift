import SwiftUI
import VoxHaloKit

@main
struct VoxHaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("VoxHalo") {
            OperatorView(model: appDelegate.environment.operatorModel)
        }
        .defaultSize(width: 760, height: 780)
    }
}
