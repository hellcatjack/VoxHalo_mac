import AppKit
import Foundation

@MainActor private final class TraceOnlyReadingCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    func start(inputUID: String) async throws {
        fatalError("Historical caption replay must never start audio capture")
    }
    func stop() async { fatalError("Historical caption replay must never stop a producer") }
}

/// Replays recorded source/MT event times through the real NativeSession visual
/// path. No models, server, audio engine or visible overlay are started. CoreText
/// supplies actual fixed-font capacity on the explicit virtual screen geometry.
@main struct NativeIndependentCaptionReplay {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw ServiceError.message("Usage: NativeIndependentCaptionReplay INPUT_JSON REPORT_JSON")
        }
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let direction = input["direction"] as? String ?? "en2zh"
        let metadata = input["metadata"] as? [String: Any] ?? [:]
        let exactMTTiming = metadata["ready_time_limitation"] == nil
        let synthetic = metadata["synthetic"] as? Bool ?? false
        let events = input["events"] as! [[String: Any]]
        guard !events.isEmpty, events.allSatisfy({ ($0["at"] as? Double ?? -1) >= 0 }),
              zip(events, events.dropFirst()).allSatisfy({ ($0["at"] as! Double) <= ($1["at"] as! Double) }) else {
            throw ServiceError.message("Replay events must be nonempty and chronologically ordered")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let session = NativeSession(capture: TraceOnlyReadingCapture(), inputDevices: { [] }, outputDevices: { [] })
        var preferences = NativePreferences(); preferences.direction = direction; preferences.outputUID = "default"
        var style = SubtitlePreferences(); style.fontSize = input["font_size"] as? Double ?? 36
        style.widthFraction = input["width_fraction"] as? Double ?? 0.8
        let screen = CGRect(x: 0, y: 0, width: input["screen_width"] as? Double ?? 1440,
                            height: input["screen_height"] as? Double ?? 900)
        session.configureReadingPresentation(splitter: {
            SubtitleTextLayout.layout(text: $0, preferences: style, screen: screen)!.pages
        }, fits: {
            SubtitleTextLayout.layout(text: $0, preferences: style, screen: screen)!.pages.count == 1
        })
        session.resetIndependentReadingForTesting(preferences: preferences)
        session.subtitleMode = .reading
        let targetLanguage = preferences.languagePair.target.code
        let minimumSeconds = SubtitleTimingPolicy.characterLanguages[targetLanguage]?.minimumSeconds
            ?? SubtitleTimingPolicy.wordLanguages[targetLanguage]?.minimumSeconds ?? 3
        var audioCallbacks = 0
        session.onPlaybackPCM = { _ in audioCallbacks += 1 }
        session.onPlaybackSchedule = { _ in audioCallbacks += 1 }
        var ready: [String: Double] = [:], shownKeys = Set<String>()
        var screens: [[String: Any]] = [], pages: [[String: Any]] = []
        var previous: CompletedSubtitleState.Identity?, peakPending = 0
        let published = input["pcm_first"] as? [String: Double] ?? [:]
        func capture(at time: Double) throws {
            peakPending = max(peakPending, session.readingPendingCount)
            guard let identity = session.subtitleIdentity, identity != previous else { return }
            previous = identity
            let references = session.playbackDiagnostics["reading_references"] as! [[String: Any]]
            let text = session.subtitleText, deadline = session.independentReadingDeadlineForTesting
            guard !text.isEmpty, !text.contains(where: { $0.isNewline }), deadline >= time + minimumSeconds - 0.001 else {
                throw ServiceError.message("A published reading screen lost its minimum or introduced a newline")
            }
            let layout = SubtitleTextLayout.layout(text: text, preferences: style, screen: screen, fitCompleteText: true)!
            assert(layout.pages.count == 1 && layout.preferences.fontSize == style.fontSize)
            screens.append(["shown_at_sec": time, "deadline_sec": deadline,
                            "reading_budget_sec": deadline - time, "text": text, "references": references])
            for reference in references {
                let id = reference["sentence_id"] as! String, revision = reference["revision"] as! Int
                let page = reference["page"] as! Int, version = "\(id)@\(revision)", key = "\(version)@\(page)"
                guard shownKeys.insert(key).inserted else { continue }
                var result: [String: Any] = ["sentence_id": id, "revision": revision, "page": page,
                                            "shown_at_sec": time]
                if let at = ready[version] {
                    result["eligible_at_sec"] = at; result["eligibility_to_shown_sec"] = time - at
                    if exactMTTiming { result["mt_ready_at_sec"] = at; result["mt_to_shown_sec"] = time - at }
                    else { result["readiness_upper_bound_sec"] = at }
                }
                if let at = published[version] {
                    result["historical_pcm_first_sec"] = at
                    result["lead_over_historical_pcm_sec"] = at - time
                }
                pages.append(result)
            }
        }
        var cursor = 0, tick = 0
        let lastEventTime = events.last!["at"] as! Double
        let hardStop = lastEventTime + 3600
        while Double(tick) * 0.05 <= hardStop {
            let now = Double(tick) * 0.05
            while cursor < events.count, (events[cursor]["at"] as! Double) <= now {
                let record = events[cursor], at = record["at"] as! Double, event = record["event"] as! [String: Any]
                if event["type"] as? String == "sentence_translation",
                   let id = event["sentence_id"] as? String, let revision = event["revision"] as? Int {
                    ready["\(id)@\(revision)"] = at
                }
                session.observeReadingEventForTesting(event, now: at)
                try capture(at: at)
                cursor += 1
            }
            _ = session.advanceIndependentReadingForTesting(now: now)
            try capture(at: now)
            assert(audioCallbacks == 0 && session.playbackTime == 0,
                   "Caption replay created or advanced audio")
            if cursor == events.count && session.readingPendingCount == 0 { break }
            tick += 1
        }
        guard cursor == events.count, session.readingPendingCount == 0 else {
            throw ServiceError.message("Replay did not drain; unread input must not be silently discarded")
        }
        if let expected = metadata["expected_translation_text"] as? String {
            let shown = screens.compactMap { $0["text"] as? String }.joined()
            assert(shown.filter { !$0.isWhitespace } == expected.filter { !$0.isWhitespace },
                   "Synthetic stress replay omitted, reordered or repeated unread text")
        }
        let delays = pages.compactMap { $0["eligibility_to_shown_sec"] as? Double }.sorted()
        let firstPages = pages.filter { $0["page"] as? Int == 0 }
        let leads = firstPages.compactMap { $0["lead_over_historical_pcm_sec"] as? Double }.sorted()
        func percentile(_ values: [Double], _ fraction: Double) -> Any {
            values.isEmpty ? NSNull() : values[min(values.count - 1, Int(Double(values.count - 1) * fraction))]
        }
        let report: [String: Any] = [
            "scope": "\(synthetic ? "Synthetic stress input" : "Historical reconstructed input") with virtual 50 ms visual ticks; real CoreText geometry; no screen paint, model inference or audio playback",
            "input_metadata": input["metadata"] ?? [:], "direction": direction, "font_size": style.fontSize,
            "screen_width": screen.width, "screen_height": screen.height, "width_fraction": style.widthFraction,
            "input_duration_sec": lastEventTime, "drained_at_sec": Double(tick) * 0.05,
            "screens": screens, "pages": pages, "screen_count": screens.count, "unique_displayed_pages": pages.count,
            "peak_pending_rows_and_cards": peakPending, "audio_callback_count": audioCallbacks,
            "exact_mt_timing": exactMTTiming,
            "eligibility_to_page_median_sec": percentile(delays, 0.5), "eligibility_to_page_p95_sec": percentile(delays, 0.95),
            "mt_to_page_median_sec": exactMTTiming ? percentile(delays, 0.5) : NSNull(),
            "mt_to_page_p95_sec": exactMTTiming ? percentile(delays, 0.95) : NSNull(),
            "first_pages_with_historical_pcm": leads.count, "first_pages_before_historical_pcm": leads.filter { $0 > 0 }.count,
            "lead_over_historical_pcm_median_sec": percentile(leads, 0.5),
            "lead_over_historical_pcm_p05_sec": percentile(leads, 0.05)
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("PASS: \(events.count) timed source/MT events, \(screens.count) immutable reading screens, \(pages.count) distinct pages, zero audio callbacks")
    }
}
