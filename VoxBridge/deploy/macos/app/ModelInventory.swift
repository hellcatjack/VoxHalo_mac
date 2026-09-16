import Foundation
import CryptoKit
import Darwin

struct ModelAsset: Decodable {
    let path: String
    let sha256: String
    let size: Int64?
    let url: String?

    var modelName: String {
        if path.contains("qwen3-asr") { return "Qwen3-ASR 0.6B" }
        if path.contains("translation-experiments") { return "HY-MT1.5 1.8B · Q8_0" }
        if path.contains("kokoro") { return path.contains("1.1-zh") ? "Kokoro 1.1 · 中文" : "Kokoro 1.0 · 多语言" }
        return "Silero VAD"
    }
    var expectedBytes: Int64? { size ?? (path.hasSuffix("kokoro-v1.1-zh-float-speed.onnx") ? 343_605_188 : nil) }
}

enum ModelFileState: String { case missing, partial, saved, verified, corrupt, unavailable }

struct ModelFile {
    let asset: ModelAsset
    let url: URL
    let state: ModelFileState
    let storedBytes: Int64
    let partialBytes: Int64
    let detail: String?
}

/// A read-only inventory. Use from one background queue; verification results
/// remain valid only while the inode, size, modification and change times match.
final class ModelInventory: @unchecked Sendable {
    private struct Manifest: Decodable { let assets: [ModelAsset]; let generated: ModelAsset? }
    let workspace: URL
    let assets: [ModelAsset]
    private var checks: [String: (String, Bool)] = [:]
    var modelDirectory: URL { workspace.appendingPathComponent("models").resolvingSymlinksInPath() }

    init(workspace: URL, manifest: URL) throws {
        self.workspace = workspace.standardizedFileURL
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        assets = value.assets.filter { $0.path.hasPrefix("models/") } + (value.generated.map { [$0] } ?? [])
        var paths = Set<String>()
        for asset in assets {
            let parts = asset.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts.first == "models", !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !asset.path.contains("\\"), paths.insert(asset.path).inserted,
                  asset.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  asset.size == nil || asset.size! > 0,
                  asset.url == nil || URL(string: asset.url!)?.scheme == "https" else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func fingerprint(_ url: URL) throws -> (String, Int64)? {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        let key = "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        return (key, value.st_size)
    }
    private func checkedURL(_ asset: ModelAsset) throws -> URL {
        var url = modelDirectory
        for part in asset.path.split(separator: "/").dropFirst() {
            url.appendPathComponent(String(part))
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw CocoaError(.fileReadUnsupportedScheme) }
        }
        return url
    }
    private func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var value = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { value.update(data: chunk) }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func scan(verify: Bool = false, onFile: ((String) -> Void)? = nil) -> [ModelFile] {
        assets.map { asset in
            let fallback = modelDirectory.appendingPathComponent(String(asset.path.dropFirst("models/".count)))
            do {
                let url = try checkedURL(asset)
                let partial = try fingerprint(url.appendingPathExtension("part"))?.1 ?? 0
                guard let (identity, bytes) = try fingerprint(url) else {
                    checks.removeValue(forKey: url.path)
                    return ModelFile(asset: asset, url: url, state: partial > 0 ? .partial : .missing,
                                     storedBytes: 0, partialBytes: partial, detail: nil)
                }
                if verify {
                    onFile?(asset.path)
                    let valid = try hash(url) == asset.sha256
                    guard try fingerprint(url)?.0 == identity else {
                        checks.removeValue(forKey: url.path)
                        return ModelFile(asset: asset, url: url, state: .saved, storedBytes: bytes, partialBytes: partial, detail: nil)
                    }
                    checks[url.path] = (identity, valid)
                }
                let checked = checks[url.path].flatMap { $0.0 == identity ? $0.1 : nil }
                let wrongSize = asset.expectedBytes.map { $0 != bytes } ?? false
                let state: ModelFileState = wrongSize || checked == false ? .corrupt : checked == true ? .verified : .saved
                return ModelFile(asset: asset, url: url, state: state, storedBytes: bytes, partialBytes: partial, detail: nil)
            } catch {
                return ModelFile(asset: asset, url: fallback, state: .unavailable, storedBytes: 0, partialBytes: 0, detail: error.localizedDescription)
            }
        }
    }
}
