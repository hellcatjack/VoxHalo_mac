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

@main struct NativeFileReplayChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 6 else {
            throw ServiceError.message("Usage: NativeFileReplayChecks ROOT PCM16_16KHZ_MONO DIRECTION REPORT_JSON OUTPUT_UID")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let pcm = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard pcm.count >= 600 * 32000, pcm.count % 2 == 0 else {
            throw ServiceError.message("Provide at least 600 seconds of raw mono PCM16 at 16 kHz")
        }
        let capture = FileReplayCapture(pcm)
        let session = NativeSession(capture: capture)
        var preferences = NativePreferences()
        preferences.direction = CommandLine.arguments[3]
        preferences.outputUID = CommandLine.arguments[5]
        guard preferences.outputUID != "none" else { throw ServiceError.message("Playback output is required") }
        var chunks: [[String: Any]] = [], samples: [[String: Any]] = [], captions: [[String: Any]] = []
        var previousCaption = "", lastDiagnostics: [String: Any] = [:]
        session.onPlaybackPCM = { chunk in
            chunks.append(["seq": chunk.seq, "sentence_id": chunk.sentence_id, "revision": chunk.revision,
                           "source_order": chunk.source_order, "index": chunk.index, "count": chunk.count,
                           "bytes": chunk.pcm.count, "duration_ms": chunk.duration_ms, "text": chunk.text])
        }
        let began = ProcessInfo.processInfo.systemUptime
        try await session.start(preferences: preferences, root: root)
        let observer = Task { @MainActor in
            var lastSample = -10.0
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let diagnostics = session.playbackDiagnostics
                if diagnostics["mode"] as? String == "pcm" { lastDiagnostics = diagnostics }
                if elapsed - lastSample >= 10 {
                    lastSample = elapsed
                    samples.append(["elapsed": elapsed, "phase": session.phase.rawValue,
                                    "source_seconds": Double(capture.sentBytes) / 32000,
                                    "playback_seconds": session.playbackTime, "backlog_seconds": session.backlogSeconds,
                                    "speed": session.speed, "source": session.sourceText, "translation": session.translationText])
                    print("\(preferences.direction) \(Int(elapsed))s: \(session.phase.rawValue), input=\(capture.sentBytes / 32000)s, chunks=\(chunks.count), backlog=\(session.backlogSeconds), speed=\(session.speed)"); fflush(stdout)
                }
                if session.subtitleText != previousCaption {
                    previousCaption = session.subtitleText
                    captions.append(["elapsed": elapsed, "text": previousCaption, "playback_seconds": session.playbackTime])
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        while !capture.finished && session.phase == .running {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let sourceComplete = capture.finished && capture.sentBytes == pcm.count
        await session.stop(drain: sourceComplete)
        observer.cancel(); await observer.value
        let failure = session.lastError ?? (!sourceComplete ? "source was interrupted" : (chunks.isEmpty ? "no synthesized PCM" : ""))
        let report: [String: Any] = ["direction": preferences.direction, "source_seconds": Double(capture.sentBytes) / 32000,
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began, "source_complete": sourceComplete,
            "phase": session.phase.rawValue, "error": failure, "chunks": chunks, "samples": samples,
            "captions": captions, "last_playback": lastDiagnostics]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
        guard failure.isEmpty, session.phase == .idle else { throw ServiceError.message(failure) }
        print("PASS: real-time file input, ASR, translation, native PCM playback, subtitles and final drain")
    }
}
