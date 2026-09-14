import Foundation

@MainActor final class ReplayCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var finished = false
    private let audio: Data
    private var task: Task<Void, Never>?
    init(audio: Data) { self.audio = audio }
    func start(inputUID: String) async throws {
        task = Task {
            for offset in stride(from: 0, to: audio.count, by: 3200) {
                if Task.isCancelled { break }
                onPCM?(audio.subdata(in: offset..<min(offset + 3200, audio.count)))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finished = true
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

@main struct NativePipelineChecks {
    @MainActor static func main() async throws {
        guard (4...5).contains(CommandLine.arguments.count) else { fatalError("usage: check ROOT PCM16_FILE REPORT_DIR [OUTPUT_UID]") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let replay = ReplayCapture(audio: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let native = NativeSession(capture: replay)
        var selected = NativePreferences(); selected.outputUID = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "none"
        let begin = Date()
        try await native.start(preferences: selected, root: root)
        assert(native.phase == .running)
        var snapshots: [[String: Any]] = [], epochs = Set<String>(), files = Set<String>()
        let http = URLSession(configuration: .ephemeral)
        func collect() async throws {
            let (data, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            snapshots.append(state)
            let tts = state["tts"] as! [String: Any]
            assert(tts["listener_count"] as? Int == 1, "browser must not be required as listener")
            assert(tts["producer_active"] as? Bool == true)
            assert((tts["last_error"] as? String ?? "").isEmpty)
            if let epoch = tts["speech_epoch_id"] as? String {
                epochs.insert(epoch)
                let folder = URL(fileURLWithPath: "/tmp/voxbridge-tts-hls-8024/\(epoch)")
                for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "ts" {
                    if !files.contains(file.lastPathComponent) {
                        if let data = try? Data(contentsOf: file) { try data.write(to: output.appendingPathComponent(file.lastPathComponent)); files.insert(file.lastPathComponent) }
                    }
                }
            }
        }
        while !replay.finished && Date().timeIntervalSince(begin) < 60 {
            try await collect()
            assert(native.phase == .running, native.lastError ?? "native session stopped")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try await collect()
        assert(epochs.count == 1, "monitor access reset shared speech epoch")
        assert(snapshots.contains { ($0["rows"] as? [[String: Any]] ?? []).contains { !($0["translation"] as? String ?? "").isEmpty } }, "no translated rows")
        let playbackTime = native.playbackTime
        if selected.outputUID != "none" { assert(playbackTime > 5, "AVPlayer did not advance") }
        await native.stop()
        assert(native.phase == .idle, native.lastError ?? "stop failed")
        let (last, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
        let stopped = try JSONSerialization.jsonObject(with: last) as! [String: Any]
        assert((stopped["session"] as! [String: Any])["status"] as? String == "stopped")
        assert((stopped["tts"] as! [String: Any])["listener_count"] as? Int == 0)
        let report: [String: Any] = ["elapsed_sec":Date().timeIntervalSince(begin),"snapshots":snapshots,"final":stopped,"hls_files":files.sorted(),"monitor_preserves_epoch":epochs.count == 1,"browser_capture_required":false,"native_session_test":true,"output_uid":selected.outputUID,"player_time_seconds":playbackTime]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("Native session start / PCM send / monitor isolation / TTS lease / graceful stop passed")
    }
}
