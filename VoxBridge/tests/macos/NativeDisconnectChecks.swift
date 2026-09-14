import Foundation

@MainActor final class DisconnectCheckCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private var task: Task<Void, Never>?
    func start(inputUID: String) async throws {
        task = Task {
            while !Task.isCancelled {
                onPCM?(Data(repeating: 0, count: 3200))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

/// Integration test: the operator terminates the owned backend after .ready,
/// writes the Unix timestamp to .down, then restarts it. Never kills services itself.
@main struct NativeDisconnectChecks {
    @MainActor static func main() async throws {
        guard (3...4).contains(CommandLine.arguments.count) else {
            throw ServiceError.message("Usage: NativeDisconnectChecks ROOT SIGNAL_FILE_PREFIX [OUTPUT_UID]")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), prefix = CommandLine.arguments[2]
        let native = NativeSession(capture: DisconnectCheckCapture())
        var preferences = NativePreferences()
        preferences.outputUID = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "none"
        try await native.start(preferences: preferences, root: root)
        try Data().write(to: URL(fileURLWithPath: prefix + ".ready"))
        print("READY: waiting for controlled backend disconnect"); fflush(stdout)
        let deadline = Date().addingTimeInterval(60)
        while native.isActive && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard native.phase == .failed else {
            await native.stop(drain: false)
            throw ServiceError.message("backend loss was not detected")
        }
        let down = try String(contentsOfFile: prefix + ".down", encoding: .utf8)
        guard let timestamp = Double(down) else { throw ServiceError.message("missing fault timestamp") }
        let latency = Date().timeIntervalSince1970 - timestamp
        guard latency >= 0 && latency < 5 else { throw ServiceError.message("disconnect detection took \(latency)s") }
        print("FAILED_AS_EXPECTED: \(native.lastError ?? "") in \(latency)s"); fflush(stdout)
        let http = URLSession(configuration: .ephemeral)
        let reconnectDeadline = Date().addingTimeInterval(90)
        var available = false
        while Date() < reconnectDeadline {
            let request = URLRequest(url: URL(string: "http://127.0.0.1:8024/api/monitor/state")!, timeoutInterval: 2)
            if let (_, response) = try? await http.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { available = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        guard available else { throw ServiceError.message("backend was not restarted") }
        try await native.start(preferences: preferences, root: root)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard native.phase == .running else { throw ServiceError.message(native.lastError ?? "reconnect failed") }
        await native.stop(drain: false)
        print("PASS: prompt disconnect detection and same-controller reconnect after backend restart")
    }
}
