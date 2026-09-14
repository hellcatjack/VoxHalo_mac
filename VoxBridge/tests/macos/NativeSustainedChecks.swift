import Foundation

@MainActor final class RepeatedSpeechCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private let audio: Data
    private var task: Task<Void, Never>?
    private(set) var blocks = 0
    init(_ audio: Data) { self.audio = audio }
    func start(inputUID: String) async throws {
        task = Task {
            while !Task.isCancelled {
                for offset in stride(from: 0, to: audio.count, by: 3200) {
                    if Task.isCancelled { return }
                    onPCM?(audio.subdata(in: offset..<min(offset + 3200, audio.count))); blocks += 1
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                for _ in 0..<30 {
                    if Task.isCancelled { return }
                    onPCM?(Data(repeating: 0, count: 3200)); blocks += 1
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

@main struct NativeSustainedChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            throw ServiceError.message("Usage: NativeSustainedChecks ROOT PCM16_16KHZ_MONO_FILE REPORT_JSON OUTPUT_UID")
        }
        let audio = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard !audio.isEmpty, audio.count % 2 == 0, audio.count <= 30 * 32000 else {
            throw ServiceError.message("Provide a PCM16 speech clip of at most 30 seconds.")
        }
        let capture = RepeatedSpeechCapture(audio)
        let native = NativeSession(capture: capture)
        var preferences = NativePreferences(); preferences.outputUID = CommandLine.arguments[4]
        preferences.contextTerms = ["尼希米 同工"]
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try await native.start(preferences: preferences, root: root)
        let began = Date()
        var samples: [[String: Any]] = [], failure: String?, previousPlayback: Double = 0
        for second in 1...180 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if native.phase != .running { failure = native.lastError ?? native.message }
            if second % 10 == 0 || failure != nil {
                let playback = native.playbackTime
                samples.append(["second": second, "elapsed": Date().timeIntervalSince(began),
                                "phase": native.phase.rawValue, "blocks": capture.blocks,
                                "player": playback, "source_chars": native.sourceText.count,
                                "translation_chars": native.translationText.count, "backlog": native.backlogSeconds])
                print("\(second)s: \(native.phase.rawValue), player=\(playback), blocks=\(capture.blocks), translation=\(native.translationText.count), error=\(native.lastError ?? "none")"); fflush(stdout)
                if preferences.outputUID != "none", playback - previousPlayback < 5 { failure = "player stopped advancing" }
                previousPlayback = playback
            }
            if failure != nil { break }
        }
        if native.sourceText.isEmpty || native.translationText.isEmpty { failure = failure ?? "missing source or translation" }
        await native.stop(drain: failure == nil)
        if native.phase != .idle { failure = failure ?? native.lastError ?? "stop failed" }
        // The same controller must be reusable, with a fresh transport and HLS lease.
        if failure == nil {
            for _ in 0..<2 {
                try await native.start(preferences: preferences, root: root)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard native.phase == .running else { throw ServiceError.message(native.lastError ?? "restart failed") }
                await native.stop(drain: false)
            }
        }
        var final: [String: Any] = [:], tts: [String: Any] = [:]
        for _ in 0..<20 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
            final = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            tts = final["tts"] as! [String: Any]
            if tts["listener_count"] as? Int == 0 && tts["producer_active"] as? Bool == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if tts["listener_count"] as? Int != 0 || tts["producer_active"] as? Bool != false { failure = failure ?? "native resources remain after stop" }
        let report: [String: Any] = ["samples": samples, "final": final, "error": failure ?? "", "elapsed": Date().timeIntervalSince(began)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        if let failure { throw ServiceError.message(failure) }
        print("PASS: 180 seconds sustained ASR / translation / playback / graceful stop / two immediate restarts")
    }
}
