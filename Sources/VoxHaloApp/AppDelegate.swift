import AppKit
import SwiftUI
import VoxHaloKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    private var operatorWindow: NSWindow?
    private var windowPresentationTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    override init() {
        environment = .live()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let window = makeOperatorWindow()
        operatorWindow = window
        application.activate()
        window.makeKeyAndOrderFront(nil)
        environment.applicationDidFinishLaunching()
        window.makeKeyAndOrderFront(nil)
        windowPresentationTask = Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let self,
                  let window,
                  self.operatorWindow === window else {
                return
            }
            application.activate()
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        windowPresentationTask?.cancel()
        windowPresentationTask = nil
        terminationTask = Task { @MainActor [environment] in
            await environment.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func makeOperatorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxHalo"
        window.minSize = NSSize(width: 680, height: 700)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("VoxHalo.OperatorWindow")
        window.contentView = NSHostingView(
            rootView: OperatorView(model: environment.operatorModel)
        )
        window.center()
        return window
    }
}
