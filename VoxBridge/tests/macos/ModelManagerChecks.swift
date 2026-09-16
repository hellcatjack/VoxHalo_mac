import Foundation

@main struct ModelManagerChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let tools = root.appendingPathComponent("model-tools")
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        let manifest = #"{"assets":[{"path":"models/vad/test.bin","size":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","url":"https://example.com/model"}]}"#
        try Data(manifest.utf8).write(to: tools.appendingPathComponent("runtime-assets.json"))
        let manager = try ModelManager(workspace: root, resources: root)
        manager.repairAvailable = true
        var decision: ((Bool) -> Void)?
        manager.onWillRepair = { decision = $0 }
        manager.repair(paths: nil)
        precondition(manager.isRepairing && decision != nil)
        decision?(false)
        precondition(!manager.isRepairing && manager.state == .failed)
        manager.repair(paths: nil)
        var settled = 0
        manager.onSettled = { settled += 1 }
        manager.cancel()
        decision?(true)
        precondition(!manager.isRepairing && manager.state == .paused, "A cancelled validation cannot later start downloading")
        manager.repair(paths: nil)
        decision?(false)
        precondition(settled == 1, "A quit completion must be consumed once, not retained for future repairs")
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("models").path))
        let file = root.appendingPathComponent("models/vad/test.bin")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: file)
        manager.refresh()
        precondition(!manager.isBusy, "Lightweight periodic refresh must not blink or disable download buttons")
        manager.refresh(verify: true)
        precondition(manager.isBusy, "A full verification requested during a refresh must be queued")
        let deadline = Date().addingTimeInterval(5)
        while (manager.isBusy || manager.scanning) && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(manager.files.first?.state == .verified, "Queued full verification must run after the lightweight scan")
        print("Model repair service gate and cancellation passed")
    }
}
