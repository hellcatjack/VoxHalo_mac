import Foundation

/// Replay the requested source once at its original speed, independent of browser capture.
@MainActor final class VideoReplayCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private let audio: Data
    private var task: Task<Void, Never>?
    private(set) var finished = false
    private(set) var blocks = 0
    init(_ audio: Data) { self.audio = audio }
    func start(inputUID: String) async throws {
        task = Task {
            let clock = ContinuousClock(), start = clock.now
            for offset in stride(from: 0, to: audio.count, by: 3200) {
                if Task.isCancelled { return }
                onPCM?(audio.subdata(in: offset..<min(offset + 3200, audio.count))); blocks += 1
                try? await clock.sleep(until: start.advanced(by: .milliseconds(blocks * 100)))
            }
            finished = true
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

@main struct NativeVideoPlaybackChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 6, let seconds = Int(CommandLine.arguments[5]), (10...600).contains(seconds) else {
            throw ServiceError.message("Usage: NativeVideoPlaybackChecks ROOT PCM16_16KHZ_MONO REPORT_DIR OUTPUT_UID SECONDS(10...600)")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard input.count >= seconds * 32000 else { throw ServiceError.message("Source is shorter than requested test.") }
        let capture = VideoReplayCapture(input.prefix(seconds * 32000))
        let native = NativeSession(capture: capture)
        var preferences = NativePreferences(); preferences.outputUID = CommandLine.arguments[4]
        preferences.contextTerms = ["尼希米", "同工"]
        let log = directory.appendingPathComponent("timeline.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let pcmLog = directory.appendingPathComponent("pcm-chunks.jsonl")
        FileManager.default.createFile(atPath: pcmLog.path, contents: nil)
        let pcmHandle = try FileHandle(forWritingTo: pcmLog); defer { try? pcmHandle.close() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 3
        let http = URLSession(configuration: configuration)
        var snapshots: [[String: Any]] = [], files = Set<String>(), failure: String?
        let began = Date()
        var lastHTTP = Date.distantPast, lastPrint = Date.distantPast
        var draining = false
        var archivedCount = 0
        var archiveFailure: String?
        native.onPlaybackPCM = { chunk in
            do {
                try chunk.pcm.write(to: directory.appendingPathComponent(String(format: "chunk-%06d.pcm", chunk.seq)))
                let item: [String: Any] = ["seq": chunk.seq, "sentence_id": chunk.sentence_id,
                    "revision": chunk.revision, "source_order": chunk.source_order, "index": chunk.index,
                    "count": chunk.count, "sample_rate": chunk.sample_rate, "duration_ms": chunk.duration_ms,
                    "created_at_ms": chunk.created_at_ms, "text": chunk.text]
                try pcmHandle.write(contentsOf: JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]))
                try pcmHandle.write(contentsOf: Data([10]))
                archivedCount += 1
            } catch { archiveFailure = error.localizedDescription }
        }
        var recordedSchedules = Set<Int>()
        func collect() async throws {
            if let archiveFailure { throw ServiceError.message(archiveFailure) }
            var sample = native.playbackDiagnostics
            let scheduled = sample["pcm_chunks"] as? [[String: Any]] ?? []
            sample["pcm_chunks"] = scheduled.filter { item in
                guard let seq = item["seq"] as? Int else { return false }
                return recordedSchedules.insert(seq).inserted
            }
            sample["elapsed"] = Date().timeIntervalSince(began); sample["wall_ms"] = Date().timeIntervalSince1970 * 1000
            sample["phase"] = native.phase.rawValue; sample["blocks"] = capture.blocks
            sample["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
            if Date().timeIntervalSince(lastHTTP) >= 0.5 {
                lastHTTP = Date()
                let listener = sample["listener"] as? String ?? ""
                if !listener.isEmpty {
                    let (data, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/tts/live/\(listener)/captions")!)
                    sample["captions"] = try JSONSerialization.jsonObject(with: data)
                }
                let (data, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
                let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                sample["monitor"] = state
                sample["monitor_elapsed"] = Date().timeIntervalSince(began)
                if let epoch = (state["tts"] as? [String: Any])?["speech_epoch_id"] as? String {
                    let folder = URL(fileURLWithPath: "/tmp/voxbridge-tts-hls-8024/\(epoch)")
                    let playlist = (try? String(contentsOf: folder.appendingPathComponent("index.m3u8"), encoding: .utf8)) ?? ""
                    // Only manifest-listed segments are complete; the newest .ts
                    // file on disk can still be growing under FFmpeg.
                    for name in playlist.components(separatedBy: .newlines) where name.hasPrefix("segment_") && name.hasSuffix(".ts") && !name.contains("/") {
                        let file = folder.appendingPathComponent(name)
                        if !files.contains(file.lastPathComponent), let data = try? Data(contentsOf: file) {
                            try data.write(to: directory.appendingPathComponent(file.lastPathComponent)); files.insert(file.lastPathComponent)
                        }
                    }
                }
            }
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])); try handle.write(contentsOf: Data([10]))
            if Date().timeIntervalSince(lastPrint) >= 30 {
                lastPrint = Date(); snapshots.append(sample)
                print("\(Int(Date().timeIntervalSince(began)))s: \(native.phase.rawValue), source=\(capture.blocks / 10)s, player=\(native.playbackTime), backlog=\(native.backlogSeconds), error=\(native.lastError ?? "none")"); fflush(stdout)
            }
        }
        try await native.start(preferences: preferences, root: root)
        while !capture.finished && Date().timeIntervalSince(began) < Double(seconds + 30) {
            do { try await collect() }
            catch { failure = "telemetry collection failed: \(error.localizedDescription)"; break }
            if native.phase != .running { failure = native.lastError ?? native.message; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !capture.finished { failure = failure ?? "source replay did not finish" }
        let shouldDrain = failure == nil
        let drain = Task { await native.stop(drain: shouldDrain); draining = true }
        while !draining {
            do { try await collect() }
            catch { failure = "drain telemetry failed: \(error.localizedDescription)"; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await drain.value
        failure = failure ?? native.lastError ?? archiveFailure
        if archivedCount == 0 { failure = failure ?? "no native PCM playback received" }
        var final: [String: Any] = [:]
        do {
            let (data, _) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
            guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tts = state["tts"] as? [String: Any] else { throw ServiceError.message("invalid final monitor state") }
            final = state
            if tts["listener_count"] as? Int != 0 || tts["producer_active"] as? Bool != false { failure = failure ?? "native resources remain" }
        } catch { failure = failure ?? "final monitor unavailable: \(error.localizedDescription)" }
        if native.translationText.isEmpty { failure = failure ?? "no translations" }
        let report: [String: Any] = ["source_seconds": Double(capture.blocks) / 10, "elapsed": Date().timeIntervalSince(began),
                                    "samples": snapshots, "final": final, "error": failure ?? "", "output_uid": preferences.outputUID]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        if let failure { throw ServiceError.message(failure) }
        print("PASS: source replay, native ASR / MT / PCM playback, graceful drain and lease cleanup")
    }
}
