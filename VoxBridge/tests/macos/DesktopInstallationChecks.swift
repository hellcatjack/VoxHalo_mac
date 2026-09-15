import Foundation

@main struct DesktopInstallationChecks {
    @MainActor static func main() throws {
        let digest = String(repeating: "a", count: 64)
        let metadata = try ReleaseMetadata(version: "1.8.0", runtimeSHA256: digest,
            runtimeUnpackedBytes: 100, modelBytes: 200, manifestSHA256: digest).validated()
        let valid = try JSONSerialization.data(withJSONObject: ["version": "1.8.0", "manifest_sha256": digest])
        let stale = try JSONSerialization.data(withJSONObject: ["version": "1.7.0", "manifest_sha256": digest])
        precondition(metadata.acceptsReadyMarker(valid))
        precondition(!metadata.acceptsReadyMarker(stale))
        precondition(!metadata.acceptsReadyMarker(Data("{}".utf8)))
        let withWheels = try ReleaseMetadata(version: "1.8.0", runtimeSHA256: digest,
            runtimeUnpackedBytes: 100, modelBytes: 200, manifestSHA256: digest,
            desktopWheelsSHA256: digest).validated()
        precondition(!withWheels.acceptsReadyMarker(valid))
        let complete = try JSONSerialization.data(withJSONObject: ["version": "1.8.0", "manifest_sha256": digest, "desktop_wheels_sha256": digest])
        precondition(withWheels.acceptsReadyMarker(complete))
        for path in ["VoxBridge/macos.sh", "./runtime/python/bin/python3", ".venv/bin/python"] {
            precondition(DesktopArchive.isSafeMember(path), path)
        }
        for path in ["/tmp/escape", "../escape", "runtime/../../escape", "", "a\u{0}b"] {
            precondition(!DesktopArchive.isSafeMember(path), path)
        }
        do {
            _ = try ReleaseMetadata(version: "../../escape", runtimeSHA256: digest,
                runtimeUnpackedBytes: 100, modelBytes: 200, manifestSHA256: digest).validated()
            fatalError("unsafe version accepted")
        } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        do { try DesktopArchive.validateExtractedTree(root); fatalError("escaping symlink accepted") } catch {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("escape"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("inside").path, withDestinationPath: "runtime")
        try DesktopArchive.validateExtractedTree(root)
        let resources = root.appendingPathComponent("resources"), dataHome = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: resources.appendingPathComponent("release.json"))
        let installer = DesktopInstallation(resources: resources, dataHome: dataHome)
        precondition(!installer.isReady && !installer.isRunning && installer.serviceRoot == nil)
        installer.start(acceptedLicenses: false, territoryEligible: true)
        precondition(!installer.isRunning && !FileManager.default.fileExists(atPath: dataHome.path))
        installer.start(acceptedLicenses: true, territoryEligible: false)
        precondition(!installer.isRunning && !FileManager.default.fileExists(atPath: dataHome.path))
        let versionRoot = dataHome.appendingPathComponent("versions/1.8.0")
        try FileManager.default.createDirectory(at: versionRoot.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versionRoot.appendingPathComponent("VoxBridge"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versionRoot.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: versionRoot.appendingPathComponent(".venv/bin/python"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versionRoot.appendingPathComponent(".venv/bin/python").path)
        try Data().write(to: versionRoot.appendingPathComponent("VoxBridge/macos.sh"))
        try Data().write(to: versionRoot.appendingPathComponent("scripts/install_desktop.py"))
        try JSONSerialization.data(withJSONObject: ["runtime_sha256": digest]).write(to: versionRoot.appendingPathComponent("runtime-installed.json"))
        try stale.write(to: versionRoot.appendingPathComponent("installed.json"))
        precondition(!DesktopInstallation(resources: resources, dataHome: dataHome).isReady)
        try valid.write(to: versionRoot.appendingPathComponent("installed.json"))
        let ready = DesktopInstallation(resources: resources, dataHome: dataHome)
        precondition(ready.isReady && ready.serviceRoot == versionRoot.appendingPathComponent("VoxBridge", isDirectory: true))
        let replaced = ReleaseMetadata(version: "1.8.0", runtimeSHA256: String(repeating: "b", count: 64), runtimeUnpackedBytes: 100, modelBytes: 200, manifestSHA256: digest)
        try JSONEncoder().encode(replaced).write(to: resources.appendingPathComponent("release.json"))
        precondition(!DesktopInstallation(resources: resources, dataHome: dataHome).isReady, "same-version payload replacement must require extraction")
        print("Desktop installation contract passed")
    }
}
