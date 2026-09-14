import Foundation

@MainActor final class SilenceCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private let speech: Data
    init(speech: Data) { self.speech = speech }
    func start(inputUID: String) async throws {
        task = Task {
            var tick = 0
            while !Task.isCancelled {
                let offset = (tick - 650) * 3200
                if offset >= 0 && offset < speech.count { onPCM?(speech.subdata(in: offset..<min(offset+3200, speech.count))) }
                else { onPCM?(Data(repeating: 0, count: 3200)) }
                tick += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

@main struct NativeLongRunChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw ServiceError.message("Usage: NativeLongRunChecks ROOT OUTPUT_UID PCM16_16KHZ_MONO_FILE")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = CommandLine.arguments[2]
        let speech = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard !speech.isEmpty, speech.count % 2 == 0, speech.count <= 32000 * 7 else {
            throw ServiceError.message("Provide a nonempty PCM16 speech clip of at most seven seconds.")
        }
        let native = NativeSession(capture: SilenceCapture(speech: speech))
        var pref = NativePreferences(); pref.outputUID = output
        try await native.start(preferences: pref, root: root)
        let begin = Date()
        var failure: String?
        for second in 1...80 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if native.phase != .running { failure = native.lastError ?? native.message; break }
            if second % 10 == 0 { print("\(second)s: producer running, player=\(native.playbackTime)"); fflush(stdout) }
        }
        if failure == nil && native.sourceText.isEmpty { failure = "speech sent after 65 seconds was never recognized" }
        let elapsed = Date().timeIntervalSince(begin)
        let playback = native.playbackTime
        await native.stop(drain: false)
        if let failure { throw ServiceError.message("failed after \(elapsed)s: \(failure)") }
        if output != "none" { precondition(playback > 65, "live player stopped advancing") }
        print("PASS: native producer survived \(elapsed)s with output \(output), and recognized speech sent after 65 seconds")
    }
}
