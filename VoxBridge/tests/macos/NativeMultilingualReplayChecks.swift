import Foundation

/// A deterministic file source using the production capture interface and clock rate.
@MainActor final class FileReplayCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private let pcm: Data
    private var task: Task<Void, Never>?
    private(set) var sentBytes = 0
    private(set) var finished = false
    init(_ pcm: Data) { self.pcm = pcm }
    func start(inputUID: String) async throws {
        sentBytes = 0; finished = false
        task = Task {
            let began = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: pcm.count, by: 3200) {
                if Task.isCancelled { return }
                let end = min(offset + 3200, pcm.count)
                onPCM?(pcm.subdata(in: offset..<end)); sentBytes = end
                let remaining = began + Double(end) / 32000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            finished = true
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

@main struct NativeMultilingualReplayChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { throw ServiceError.message("Usage: checks ROOT PCM_DIRECTORY REPORT_JSON") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        var results: [[String: Any]] = []
        for (index, source) in NativeLanguage.all.enumerated() {
            let target = NativeLanguage.all[(index + 1) % NativeLanguage.all.count]
            let direction = "\(source.code)2\(target.code)"
            let pcm = try Data(contentsOf: directory.appendingPathComponent(source.code + ".pcm"))
            let capture = FileReplayCapture(pcm)
            let session = NativeSession(capture: capture)
            var preferences = NativePreferences(); preferences.direction = direction; preferences.outputUID = "default"
            var chunks: [[String: Any]] = []
            session.onPlaybackPCM = { chunk in
                chunks.append(["seq": chunk.seq, "text": chunk.text, "bytes": chunk.pcm.count,
                               "source_order": chunk.source_order, "index": chunk.index, "count": chunk.count])
            }
            let began = Date()
            try await session.start(preferences: preferences, root: root)
            while !capture.finished && session.phase == .running {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            await session.stop(drain: capture.finished)
            let row: [String: Any] = ["direction": direction, "input_seconds": Double(pcm.count)/32000,
                "elapsed_seconds": Date().timeIntervalSince(began), "source_complete": capture.finished,
                "phase": session.phase.rawValue, "error": session.lastError ?? "", "chunks": chunks,
                "source": session.sourceText, "translation": session.translationText]
            results.append(row)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            print("\(direction): \(chunks.count) speech chunks, \(session.phase.rawValue), source=\(session.sourceText), target=\(session.translationText)"); fflush(stdout)
            guard capture.finished, session.phase == .idle, session.lastError == nil, !chunks.isEmpty else {
                throw ServiceError.message("Multilingual replay failed: \(direction), \(session.lastError ?? "no PCM")")
            }
        }
        print("PASS: eight source/target languages through actual native ASR, translation and PCM playback")
    }
}
