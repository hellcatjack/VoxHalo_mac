import Foundation
import CryptoKit
import Darwin

struct ReleaseMetadata: Codable {
    let version: String
    let runtimeSHA256: String
    let runtimeUnpackedBytes: Int64
    let modelBytes: Int64
    let manifestSHA256: String
    let desktopWheelsSHA256: String?
    init(version: String, runtimeSHA256: String, runtimeUnpackedBytes: Int64, modelBytes: Int64,
         manifestSHA256: String, desktopWheelsSHA256: String? = nil) {
        self.version = version; self.runtimeSHA256 = runtimeSHA256; self.runtimeUnpackedBytes = runtimeUnpackedBytes
        self.modelBytes = modelBytes; self.manifestSHA256 = manifestSHA256; self.desktopWheelsSHA256 = desktopWheelsSHA256
    }
    enum CodingKeys: String, CodingKey {
        case version, runtimeSHA256 = "runtime_sha256", runtimeUnpackedBytes = "runtime_unpacked_bytes"
        case modelBytes = "model_bytes", manifestSHA256 = "manifest_sha256"
        case desktopWheelsSHA256 = "desktop_wheels_sha256"
    }
    func validated() throws -> Self {
        let digest = "^[a-fA-F0-9]{64}$"
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil,
              !version.contains(".."), runtimeSHA256.range(of: digest, options: .regularExpression) != nil,
              manifestSHA256.range(of: digest, options: .regularExpression) != nil,
              desktopWheelsSHA256 == nil || desktopWheelsSHA256?.range(of: digest, options: .regularExpression) != nil,
              runtimeUnpackedBytes > 0, modelBytes >= 0,
              runtimeUnpackedBytes < Int64.max / 4, modelBytes < Int64.max / 4 else {
            throw DesktopInstallError.message("安装包元数据无效，请重新下载 App。")
        }
        return self
    }
    func acceptsReadyMarker(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["version"] as? String == version && value["manifest_sha256"] as? String == manifestSHA256
            && (desktopWheelsSHA256 == nil || value["desktop_wheels_sha256"] as? String == desktopWheelsSHA256)
    }
    func hasInstalledRuntime(at root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("runtime-installed.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              value["runtime_sha256"] == runtimeSHA256 else { return false }
        return FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/install_desktop.py").path)
    }
}

enum DesktopInstallError: LocalizedError {
    case message(String), cancelled
    var errorDescription: String? {
        switch self {
        case .message(let value): return NativeLocalization.render(value)
        case .cancelled: return NativeLocalization.text("安装已取消。已下载的文件会保留，可稍后继续。")
        }
    }
}

enum DesktopArchive {
    static func isSafeMember(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\0") &&
        !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
    /// BSD tar rejects writes through escaping links. Check the resulting tree as well,
    /// before executing any bundled code or publishing the version directory.
    static func validateExtractedTree(_ root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else {
            throw DesktopInstallError.message("安装包解压失败，请重试。")
        }
        for case let entry as URL in entries {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(base) || resolved + "/" == base else {
                    throw DesktopInstallError.message("安装包包含不安全路径，请重新下载 App。")
                }
            } else if values.isRegularFile != true && values.isDirectory != true {
                throw DesktopInstallError.message("安装包包含不安全路径，请重新下载 App。")
            }
        }
    }
}

struct DesktopInstallEvent: Decodable {
    let phase: String
    let message: String?
    let asset: String?
    let completedBytes: Int64?
    let totalBytes: Int64?
    enum CodingKeys: String, CodingKey {
        case phase, message, asset, completedBytes = "completed_bytes", totalBytes = "total_bytes"
    }
}

/// All filesystem work, hashing and child-process reads run on one background queue.
/// The lock allows cancellation while a process is running or between archive chunks.
private final class DesktopInstallWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    var onLine: ((String) -> Void)?
    var onPhase: ((String) -> Void)?

    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning {
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw DesktopInstallError.cancelled }
    }
    private func run(_ executable: URL, _ arguments: [String], directory: URL? = nil,
                     emitLines: Bool = false) throws -> String {
        try checkCancellation()
        let child = Process(), pipe = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.currentDirectoryURL = directory
        child.standardOutput = pipe; child.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"] { environment.removeValue(forKey: key) }
        environment["PYTHONNOUSERSITE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw DesktopInstallError.cancelled }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); process = nil; lock.unlock() }
        var buffer = Data(), output = ""
        while let data = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty {
            buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                if emitLines { onLine?(line) } else { output += line + "\n" }
            }
            if buffer.count > 1024 * 1024 {
                let line = String(decoding: buffer, as: UTF8.self); buffer.removeAll()
                if emitLines { onLine?(line) } else { output += line }
            }
        }
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            if emitLines { onLine?(line) } else { output += line }
        }
        child.waitUntilExit()
        try checkCancellation()
        guard child.terminationStatus == 0 else {
            if !output.isEmpty { onLine?(output) }
            throw DesktopInstallError.message("安装未完成。请查看安装详情后重试。")
        }
        return output
    }
    private func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func install(resources: URL, dataHome: URL, metadata: ReleaseMetadata, repairCorrupt: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataHome, withIntermediateDirectories: true)
        let descriptor = Darwin.open(dataHome.appendingPathComponent(".bootstrap.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DesktopInstallError.message("无法写入安装目录。请检查磁盘权限。") }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw DesktopInstallError.message("另一个安装任务正在运行。请等待其结束后重试。")
        }
        try checkCancellation(); onPhase?("checking")
        #if !arch(arm64)
        throw DesktopInstallError.message("需要 Apple Silicon Mac、macOS 14.2 或更新版本以及至少 16 GB 内存。")
        #endif
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)),
              ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024 else {
            throw DesktopInstallError.message("需要 Apple Silicon Mac、macOS 14.2 或更新版本以及至少 16 GB 内存。")
        }
        let available = (try fm.attributesOfFileSystem(forPath: dataHome.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let required = max(20_000_000_000, metadata.runtimeUnpackedBytes + metadata.modelBytes + 2_000_000_000)
        // Completed and partial files count toward the original disk allowance on retry.
        var allocated: Int64 = 0
        if let files = fm.enumerator(at: dataHome, includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey]) {
            for case let file as URL in files {
                try checkCancellation()
                if let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey]), value.isRegularFile == true {
                    allocated += Int64(value.fileAllocatedSize ?? 0)
                }
            }
        }
        guard available >= 2_000_000_000, available + allocated >= required else {
            throw DesktopInstallError.message("磁盘空间不足。请至少腾出 20 GB 后重试。")
        }
        let versions = dataHome.appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let root = versions.appendingPathComponent(metadata.version, isDirectory: true)
        if !metadata.hasInstalledRuntime(at: root) {
            let archive = resources.appendingPathComponent("runtime.tar.gz")
            onPhase?("verifying")
            guard try sha256(archive) == metadata.runtimeSHA256.lowercased() else {
                throw DesktopInstallError.message("安装包校验失败，请重新下载 App。")
            }
            let listing = try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tzf", archive.path])
            let members = listing.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            guard !members.isEmpty, members.allSatisfy({ DesktopArchive.isSafeMember(String($0)) }) else {
                throw DesktopInstallError.message("安装包包含不安全路径，请重新下载 App。")
            }
            let stage = versions.appendingPathComponent(".stage-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            onPhase?("preparing")
            _ = try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", stage.path,
                "--no-same-owner", "--no-same-permissions", "--safe-writes"])
            try checkCancellation(); try DesktopArchive.validateExtractedTree(stage)
            guard fm.isExecutableFile(atPath: stage.appendingPathComponent(".venv/bin/python").path),
                  fm.fileExists(atPath: stage.appendingPathComponent("scripts/install_desktop.py").path) else {
                throw DesktopInstallError.message("安装包解压失败，请重试。")
            }
            let stamp = try JSONSerialization.data(withJSONObject: ["runtime_sha256": metadata.runtimeSHA256])
            try stamp.write(to: stage.appendingPathComponent("runtime-installed.json"), options: .atomic)
            let backup = versions.appendingPathComponent(".previous-" + UUID().uuidString)
            if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: backup) }
            do { try fm.moveItem(at: stage, to: root) }
            catch { if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: root) }; throw error }
            try? fm.removeItem(at: backup)
        }
        try checkCancellation()
        let consent = try JSONSerialization.data(withJSONObject: ["version": metadata.version,
            "manifest_sha256": metadata.manifestSHA256, "accepted": true, "territory_eligible": true])
        try consent.write(to: root.appendingPathComponent("license-consent.json"), options: .atomic)
        var arguments = ["-u", root.appendingPathComponent("scripts/install_desktop.py").path,
            "--root", root.path, "--assets-root", dataHome.appendingPathComponent("assets").path, "--events-json"]
        if repairCorrupt { arguments.append("--repair-corrupt") }
        _ = try run(root.appendingPathComponent(".venv/bin/python"), arguments,
            directory: root, emitLines: true)
        let marker = try Data(contentsOf: root.appendingPathComponent("installed.json"))
        guard metadata.acceptsReadyMarker(marker) else {
            throw DesktopInstallError.message("安装结果校验失败，请重试。")
        }
    }
}

@MainActor final class DesktopInstallation {
    enum State { case consent, working, cancelled, failed, ready }
    let resources: URL
    let dataHome: URL
    let metadata: ReleaseMetadata?
    private(set) var state: State = .consent
    private(set) var phase = "checking"
    private(set) var event: DesktopInstallEvent?
    private(set) var message = "首次使用需要安装本机模型。"
    private(set) var details = ""
    private(set) var needsRepair = false
    private var worker: DesktopInstallWorker?
    var onChange: (() -> Void)?
    var onReady: (() -> Void)?
    var onSettled: (() -> Void)?
    var onActivityChange: (() -> Void)?
    var isReady: Bool { state == .ready }
    var isRunning: Bool { state == .working }
    var serviceRoot: URL? {
        guard isReady, let metadata else { return nil }
        return dataHome.appendingPathComponent("versions/\(metadata.version)/VoxBridge", isDirectory: true)
    }
    var logURL: URL { dataHome.appendingPathComponent("installation.log") }

    static func bundled() -> DesktopInstallation? {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("release.json").path) else { return nil }
        return DesktopInstallation(resources: resources)
    }
    init(resources: URL, dataHome: URL? = nil) {
        self.resources = resources
        let override = ProcessInfo.processInfo.environment["VOXHALO_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.dataHome = dataHome ?? override ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoxHalo", isDirectory: true)
        do {
            let value = try JSONDecoder().decode(ReleaseMetadata.self, from: Data(contentsOf: resources.appendingPathComponent("release.json"))).validated()
            metadata = value
            let root = self.dataHome.appendingPathComponent("versions/\(value.version)")
            if let data = try? Data(contentsOf: root.appendingPathComponent("installed.json")), value.acceptsReadyMarker(data),
               value.hasInstalledRuntime(at: root),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("VoxBridge/macos.sh").path) {
                state = .ready; phase = "ready"
            }
        } catch { metadata = nil; state = .failed; message = "安装包元数据无效，请重新下载 App。"; details = error.localizedDescription }
    }
    func start(acceptedLicenses: Bool, territoryEligible: Bool, repairCorrupt: Bool = false) {
        guard !isRunning, let metadata else { return }
        guard acceptedLicenses && territoryEligible else {
            message = "请阅读模型许可证，并确认您符合 HY-MT 的使用地区要求。"; onChange?(); return
        }
        state = .working; phase = "checking"; event = nil; message = "正在检查安装条件…"; needsRepair = false
        let running = DesktopInstallWorker(); worker = running
        running.onLine = { [weak self] line in Task { @MainActor [weak self] in self?.receive(line) } }
        running.onPhase = { [weak self] phase in Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.phase = phase; self.event = nil; self.onChange?()
        } }
        onChange?(); onActivityChange?()
        let resources = self.resources, home = dataHome
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try running.install(resources: resources, dataHome: home, metadata: metadata, repairCorrupt: repairCorrupt) }
            Task { @MainActor [weak self] in self?.finished(result) }
        }
    }
    func cancel() {
        guard isRunning else { return }
        message = "正在取消安装…"; worker?.cancel(); onChange?()
    }
    private func receive(_ line: String) {
        guard isRunning else { return }
        if let parsed = try? JSONDecoder().decode(DesktopInstallEvent.self, from: Data(line.utf8)) {
            event = parsed; phase = parsed.phase
        }
        details += line + "\n"
        if ["Existing asset differs", "Existing generated model differs", "Existing wheel file differs"].contains(where: line.contains) { needsRepair = true }
        if details.count > 60_000 { details = String(details.suffix(50_000)) }
        onChange?()
    }
    private func finished(_ result: Result<Void, Error>) {
        worker = nil
        switch result {
        case .success: state = .ready; phase = "ready"; message = "本机模型已就绪。"
        case .failure(let error):
            if case DesktopInstallError.cancelled = error { state = .cancelled }
            else { state = .failed }
            switch error {
            case DesktopInstallError.message(let source): message = source
            case DesktopInstallError.cancelled: message = "安装已取消。已下载的文件会保留，可稍后继续。"
            default: message = "安装未完成。请查看安装详情后重试。"
            }
            details += "\n" + error.localizedDescription + "\n"
        }
        // The bounded log remains available after closing the installer window.
        try? FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        try? Data(details.utf8).write(to: logURL, options: .atomic)
        onChange?(); onActivityChange?(); onSettled?()
        if isReady { onReady?() }
    }
}
