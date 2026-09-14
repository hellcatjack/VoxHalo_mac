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

@main struct NativeSubtitlePipelineChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            throw ServiceError.message("Usage: NativeSubtitlePipelineChecks ROOT CHINESE_PCM ENGLISH_PCM REPORT")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let capture = DirectionReplayCapture()
        let controller = NativeSession(capture: capture)
        var reports: [[String: Any]] = []
        for (pair, path) in [(NativeTranslationDirection.zh2en, CommandLine.arguments[2]), (.en2zh, CommandLine.arguments[3])] {
            capture.audio = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(13 * 32000)
            guard capture.audio.count > 32000 else { throw ServiceError.message("fixture is too short") }
            var preferences = NativePreferences(); preferences.direction = pair.rawValue; preferences.outputUID = "none"
            var subtitles: [[String: Any]] = [], previous = "", partialBeforeSubtitle = false
            let began = Date()
            controller.onChange = {
                if !controller.sourceText.isEmpty && controller.subtitleText.isEmpty { partialBeforeSubtitle = true }
                let text = controller.subtitleText
                if text != previous {
                    subtitles.append(["seconds": Date().timeIntervalSince(began), "text": text, "phase": controller.phase.rawValue])
                    previous = text
                    print("SUBTITLE \(pair.rawValue): \(text)"); fflush(stdout)
                }
            }
            try await controller.start(preferences: preferences, root: root)
            assert(controller.subtitleText.isEmpty, "previous session caption leaked into start")
            do {
                while !capture.finished {
                    guard controller.phase == .running, Date().timeIntervalSince(began) < 40 else {
                        throw ServiceError.message(controller.lastError ?? "capture did not finish")
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                await controller.stop(drain: true)
                guard controller.phase == .idle, controller.lastError == nil else {
                    throw ServiceError.message(controller.lastError ?? "session did not drain")
                }
                assert(controller.subtitleText.isEmpty, "caption survived full stop")
                let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8024/api/monitor/state")!)
                let monitor = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let rows = monitor["rows"] as? [[String: Any]] ?? []
                let completeTexts = Set(rows.compactMap { $0["translation"] as? String }.filter { !$0.isEmpty })
                let shown = subtitles.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
                assert(!shown.isEmpty, "no completed subtitle received from the real socket")
                assert(Set(shown).isSubset(of: completeTexts), "subtitle was not a complete backend translation")
                assert(shown.allSatisfy { ($0.range(of: "[\\u3400-\\u9fff]", options: .regularExpression) != nil) == (pair == .en2zh) })
                let tts = monitor["tts"] as! [String: Any]
                assert(tts["listener_count"] as? Int == 0 && tts["producer_active"] as? Bool == false)
                reports.append(["direction": pair.rawValue, "source_seconds": Double(capture.audio.count) / 32000,
                                "subtitles": subtitles, "partial_before_subtitle": partialBeforeSubtitle, "final": monitor])
                print("PASS \(pair.title): completed-only subtitles, cleared on stop, producer/listener released"); fflush(stdout)
            } catch { await controller.stop(drain: false); throw error }
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
    }
}
