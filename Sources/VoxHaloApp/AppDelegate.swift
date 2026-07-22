import AppKit
import VoxHaloKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    private var terminationTask: Task<Void, Never>?

    override init() {
        environment = .live()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.applicationDidFinishLaunching()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [environment] in
            await environment.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
