import Foundation

struct ServiceProcess: Decodable {
    let pid: Int?
    let ready: Bool
}

struct ServiceSnapshot: Decodable {
    let services: [String: ServiceProcess]
    let busy: Bool
    let listener_url: String?
    let lan_error: String?
    let operator_url: String
    let logs_path: String
    let service_error: String?
    let restart_required: Bool?

    var isReady: Bool { services["app"]?.ready == true && services["translation"]?.ready == true }
    var hasProcess: Bool { services.values.contains { $0.pid != nil } }
}

enum ServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

final class ServiceClient {
    let root: URL
    private let queue = DispatchQueue(label: "org.pccs.voxbridge.service", qos: .userInitiated)

    init(root: URL) { self.root = root.standardizedFileURL }

    var python: URL { root.deletingLastPathComponent().appendingPathComponent(".venv/bin/python") }
    var script: URL { root.appendingPathComponent("tools/macos_service.py") }
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: script.path)
    }

    // No shell interpolation: spaces and non-ASCII installation paths stay intact.
    func run(_ action: String, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            let result: Result<Data, Error>
            do {
                guard self.isInstalled else {
                    throw ServiceError.message("找不到服务或 Python 环境。请选择包含 macos.sh 的 VoxBridge 文件夹。")
                }
                let process = Process()
                process.executableURL = self.python
                process.arguments = [self.script.path, action]
                process.currentDirectoryURL = self.root
                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONUNBUFFERED"] = "1"
                environment["PYTHONIOENCODING"] = "utf-8"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let detail = String(data: data, encoding: .utf8) ?? "服务命令执行失败。"
                    throw ServiceError.message(String(detail.suffix(6000)).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                result = .success(data)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func runAsync(_ action: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            run(action) { continuation.resume(with: $0) }
        }
    }

    func snapshot(completion: @escaping (Result<ServiceSnapshot, Error>) -> Void) {
        run("app-status") { result in
            completion(result.flatMap { data in
                Result { try JSONDecoder().decode(ServiceSnapshot.self, from: data) }
            })
        }
    }
}
