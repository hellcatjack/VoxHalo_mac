import AppKit

@main struct InstallationWindowChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain(["interfaceLanguage": "zh"], forName: UserDefaults.argumentDomain)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ReleaseMetadata(version: "1.8.0", runtimeSHA256: String(repeating: "a", count: 64),
            runtimeUnpackedBytes: 100, modelBytes: 200, manifestSHA256: String(repeating: "b", count: 64))
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("release.json"))
        let home = root.appendingPathComponent("data")
        let installation = DesktopInstallation(resources: root, dataHome: home)
        let controller = InstallationWindow(installation: installation)
        let window = app.windows.first { $0.title == "安装本机模型" }!
        func acceptConsent(_ view: NSView) {
            if let button = view as? NSButton, button.title.isEmpty,
               button.accessibilityLabel()?.hasPrefix("我") == true { button.state = .on }
            for child in view.subviews { acceptConsent(child) }
        }
        acceptConsent(window.contentView!)
        var decision: ((Bool) -> Void)?
        controller.onWillStart = { decision = $0 }
        _ = controller.perform(NSSelectorFromString("start"))
        precondition(decision != nil && !installation.isRunning)
        decision?(false)
        precondition(!installation.isRunning && !FileManager.default.fileExists(atPath: home.path), "service check denial must prevent installer mutation")
        _ = controller.perform(NSSelectorFromString("start"))
        _ = controller.windowShouldClose(window)
        decision?(true)
        precondition(!installation.isRunning && !FileManager.default.fileExists(atPath: home.path), "closing while checking must invalidate a later successful response")
        print("Installation window start gate passed")
    }
}
