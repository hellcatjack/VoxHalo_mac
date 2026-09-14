import Foundation

/// Reuse one controller across directions; feed bounded fixtures at real time.
@MainActor final class DirectionReplayCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var audio = Data()
    private(set) var finished = false
    private var task: Task<Void, Never>?
    func start(inputUID: String) async throws {
        finished = false
        task = Task {
            let clock = ContinuousClock(), began = clock.now
            for offset in stride(from: 0, to: audio.count, by: 3200) {
                if Task.isCancelled { return }
                onPCM?(audio.subdata(in: offset..<min(offset + 3200, audio.count)))
                try? await clock.sleep(until: began.advanced(by: .milliseconds((offset / 3200 + 1) * 100)))
            }
            finished = true
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

@main struct NativeBidirectionalChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            throw ServiceError.message("Usage: NativeBidirectionalChecks ROOT CHINESE_PCM ENGLISH_PCM REPORT_DIR")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let chinese = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let english = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard [chinese, english].allSatisfy({ $0.count > 32000 && $0.count <= 60 * 32000 && $0.count % 2 == 0 }) else {
            throw ServiceError.message("Each fixture must be 1–60 seconds of mono PCM16/16kHz.")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let capture = DirectionReplayCapture()
        // Keep one NativeSession and one capture for all three runs.
        let session = NativeSession(capture: capture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let http = URLSession(configuration: configuration)
        func monitor() async throws -> [String: Any] {
            let (data, response) = try await http.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.message("monitor unavailable") }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        var reports: [[String: Any]] = [], epochs = Set<String>()
        for (index, pair) in [NativeTranslationDirection.zh2en, .en2zh, .zh2en].enumerated() {
            capture.audio = pair == .zh2en ? chinese : english
            var preferences = NativePreferences(); preferences.direction = pair.rawValue
            preferences.outputUID = "default"
            let directory = output.appendingPathComponent("\(index + 1)-\(pair.rawValue)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var chunks: [NativeSpeechChunk] = [], archiveError: Error?
            session.onPlaybackPCM = { chunk in
                chunks.append(chunk)
                do { try chunk.pcm.write(to: directory.appendingPathComponent("chunk-\(chunk.seq).pcm")) }
                catch { archiveError = error }
            }
            let began = Date()
            var snapshots: [[String: Any]] = []
            try await session.start(preferences: preferences, root: root)
            print("START \(pair.title), source \(Double(capture.audio.count) / 32000)s"); fflush(stdout)
            do {
                let initial = try await monitor()
                assert((initial["rows"] as? [[String: Any]] ?? []).isEmpty, "previous direction subtitles survived start")
                if let epoch = session.playbackDiagnostics["epoch"] as? String {
                    assert(epochs.insert(epoch).inserted, "previous playback epoch survived full stop")
                }
                var stopped = false
                while !capture.finished {
                    guard session.phase == .running, Date().timeIntervalSince(began) < 90 else {
                        throw ServiceError.message(session.lastError ?? "fixture playback did not finish")
                    }
                    let state = try await monitor()
                    assert((state["session"] as? [String: Any])?["direction"] as? String == pair.rawValue)
                    snapshots.append(state)
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                let drain = Task { await session.stop(drain: true); stopped = true }
                while !stopped {
                    snapshots.append(try await monitor())
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                await drain.value
                guard session.phase == .idle, session.lastError == nil else {
                    throw ServiceError.message(session.lastError ?? "drain failed")
                }
                if let archiveError { throw archiveError }
                assert(!chunks.isEmpty && chunks.contains { $0.pcm.contains { $0 != 0 } }, "no audible PCM received")
                for group in Dictionary(grouping: chunks, by: { $0.sentence_id }).values {
                    assert(group.count == group[0].count && group.map(\.index) == Array(0..<group.count), "sentence chunks lost")
                }
                let final = try await monitor(), tts = final["tts"] as! [String: Any]
                assert(tts["listener_count"] as? Int == 0 && tts["producer_active"] as? Bool == false)
                assert((tts["last_error"] as? String ?? "").isEmpty)
                let rows = final["rows"] as? [[String: Any]] ?? []
                assert(rows.contains { !(($0["translation"] as? String) ?? "").isEmpty })
                let speech = chunks.map(\.text).joined()
                let hasChinese = speech.range(of: "[\\u3400-\\u9fff]", options: .regularExpression) != nil
                assert(hasChinese == (pair == .en2zh), "speech text has the wrong target language")
                let chunkInfo: [[String: Any]] = chunks.map { ["seq": $0.seq, "sentence_id": $0.sentence_id,
                    "index": $0.index, "count": $0.count, "duration_ms": $0.duration_ms, "text": $0.text] }
                let report: [String: Any] = ["direction": pair.rawValue, "source_seconds": Double(capture.audio.count) / 32000,
                    "elapsed": Date().timeIntervalSince(began), "final": final, "chunks": chunkInfo, "snapshots": snapshots]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("report.json"))
                reports.append(report)
                print("PASS \(pair.title): \(rows.count) rows, \(chunks.count) PCM chunks, drained and released"); fflush(stdout)
            } catch {
                await session.stop(drain: false)
                throw error
            }
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("PASS: one native controller switched Chinese → English → Chinese source languages with real local ASR/MT/TTS")
    }
}
