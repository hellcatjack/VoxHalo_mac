import Foundation
import CryptoKit

@main struct ModelInventoryChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let value: [String: Any] = ["assets": [["path": "models/vad/silero_vad.onnx", "url": "https://example.com/model", "size": 3, "sha256": digest]]]
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        let inventory = try ModelInventory(workspace: root, manifest: manifest)
        let file = root.appendingPathComponent("models/vad/silero_vad.onnx")
        precondition(inventory.scan()[0].state == .missing)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = file.appendingPathExtension("part")
        try Data("a".utf8).write(to: part)
        precondition(inventory.scan()[0].state == .partial && inventory.scan()[0].partialBytes == 1)
        try Data("abc".utf8).write(to: file)
        precondition(inventory.scan()[0].state == .saved, "Size alone must not claim checksum verification")
        precondition(inventory.scan(verify: true)[0].state == .verified)
        try Data("bad".utf8).write(to: file, options: .atomic)
        precondition(inventory.scan()[0].state == .saved, "Replacing a file invalidates a cached verification")
        precondition(inventory.scan(verify: true)[0].state == .corrupt)
        precondition(inventory.scan()[0].state == .corrupt)
        try fm.removeItem(at: file); try fm.removeItem(at: part)
        precondition(inventory.scan()[0].state == .missing, "A prior verified result cannot hide deletion")
        let external = root.appendingPathComponent("external")
        try Data("abc".utf8).write(to: external)
        try fm.createSymbolicLink(at: file, withDestinationURL: external)
        precondition(inventory.scan()[0].state == .unavailable, "Inner symlinks must never look repairable")
        try fm.removeItem(at: root.appendingPathComponent("models"))
        let shared = root.appendingPathComponent("assets/models")
        try fm.createDirectory(at: shared.appendingPathComponent("vad"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: shared.appendingPathComponent("vad/silero_vad.onnx"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: shared)
        let release = try ModelInventory(workspace: root, manifest: manifest)
        precondition(release.scan()[0].url.path == shared.appendingPathComponent("vad/silero_vad.onnx").path)
        precondition(release.scan(verify: true)[0].state == .verified)
        print("Model inventory: missing, partial, verified, tampered, deleted, links and actual paths passed")
    }
}
