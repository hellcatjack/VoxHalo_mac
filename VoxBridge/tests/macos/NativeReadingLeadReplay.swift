import Foundation
import AppKit
import CryptoKit

/// Standalone acceptance harness, compiled with -D NATIVE_PLAYBACK_TESTING and
/// the production native App sources. Run only after its current producer stops:
/// NativeReadingLeadReplay ROOT PCM16_16KHZ_MONO DIRECTION REPORT_JSON OUTPUT_UID
/// Input must contain at least 10 seconds. This uses real ASR/MT/TTS and audible
/// native output and the production floating overlay with actual screen/font
/// geometry. Reports capture AppKit screen draws, not physical speaker/screen
/// recordings. It saves no preferences.
@MainActor private final class ReadingLeadFileCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private let pcm: Data
    private var task: Task<Void, Never>?
    private(set) var sentBytes = 0
    private(set) var finished = false

    init(pcm: Data) { self.pcm = pcm }

    func start(inputUID: String) async throws {
        sentBytes = 0; finished = false
        task = Task {
            let began = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: pcm.count, by: 3200) {
                guard !Task.isCancelled else { return }
                let end = min(offset + 3200, pcm.count)
                onPCM?(pcm.subdata(in: offset..<end)); sentBytes = end
                onLevel?(0.25)
                let remaining = began + Double(end) / 32000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
            finished = true
        }
    }

    func stop() async { task?.cancel(); await task?.value; task = nil }
}

private func readingLeadInteger(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}

private func readingLeadCompact(_ text: String) -> String {
    String(text.filter { !$0.isWhitespace })
}

private func readingLeadReferenceSequence(_ reference: [String: Any]) -> Int? {
    readingLeadInteger(reference["first_sequence"] ?? reference["firstSequence"] ?? reference["seq"]).map(Int.init)
}

private func readingLeadReferenceStart(_ reference: [String: Any]) -> Int64? {
    readingLeadInteger(reference["start_frame"] ?? reference["startFrame"])
}

private func readingLeadReferenceMatches(_ reference: [String: Any], timing: [String: Any]) -> Bool {
    let id = reference["sentence_id"] as? String ?? reference["sentenceID"] as? String ?? reference["id"] as? String
    let order = readingLeadInteger(reference["source_order"] ?? reference["sourceOrder"])
    return id == timing["sentence_id"] as? String &&
        readingLeadInteger(reference["revision"]) == readingLeadInteger(timing["revision"]) &&
        (order == nil || order == readingLeadInteger(timing["source_order"]))
}

/// Repeated occurrences can legitimately reuse identical, already painted
/// pixels. Rebind only a complete exact text match; retain the original physical
/// paint time, and measure this occurrence from its new visibility binding.
func nativeReadingRebindUnchangedPaint(_ paint: [String: Any], diagnostics: [String: Any],
                                      uptime: TimeInterval) -> [String: Any]? {
    guard let text = diagnostics["reading_text"] as? String, !text.isEmpty,
          paint["painted_text"] as? String == text, paint["visible_text"] as? String == text,
          diagnostics["reading_sentence_id"] as? String != paint["reading_sentence_id"] as? String else { return nil }
    var rebound = diagnostics
    for key in ["paint_uptime", "painted_text", "visible_text", "screen_drawing", "window_visible", "forced_offscreen"] {
        rebound[key] = paint[key]
    }
    rebound["pixel_reuse"] = true
    rebound["visibility_binding_uptime"] = uptime
    rebound["presented_frame"] = diagnostics["subtitle_presented_frame"] ?? NSNull()
    return rebound
}

/// Compare painted physical pages with accepted PCM occurrence/page anchors.
/// A page need not contain its entire PCM chunk; anchors within a long chunk are
/// proportional text-work estimates, not word alignment.
func nativeReadingPaintCoverage(frame: Int64, timing: [String: Any], chunkText: String,
                                visibleText: String, visibleReferences: [[String: Any]],
                                expectedReferences: [[String: Any]], visibleTarget: Int64?) -> String {
    if let visibleTarget, visibleTarget > frame + LiveReadingSubtitle.leadFrames { return "premature_page" }
    let matching = visibleReferences.filter { readingLeadReferenceMatches($0, timing: timing) }
    if !matching.isEmpty, !visibleText.isEmpty {
        let paintedPage = matching.compactMap { readingLeadInteger($0["page"]) }.max() ?? 0
        let duePage = expectedReferences.filter {
            readingLeadReferenceMatches($0, timing: timing) && (readingLeadReferenceStart($0).map { $0 <= frame } ?? false)
        }.compactMap { readingLeadInteger($0["page"]) }.max() ?? 0
        if paintedPage < duePage { return "lagging_past_page" }
        return readingLeadCompact(visibleText).contains(readingLeadCompact(chunkText))
            ? "covered_current_occurrence" : "covered_current_physical_page"
    }
    if visibleReferences.contains(where: { reference in
        guard let nextStart = readingLeadReferenceStart(reference), let visibleTarget else { return false }
        return nextStart > frame && nextStart <= visibleTarget && nextStart - frame <= 14400
    }) { return "expected_lead_transition" }
    if visibleReferences.contains(where: { reference in
        guard let prior = readingLeadInteger(reference["source_order"] ?? reference["sourceOrder"]),
              let current = readingLeadInteger(timing["source_order"]) else { return false }
        return prior < current
    }) { return "lagging_past_occurrence" }
    return "missing_current_occurrence"
}

/// Same 10 ms RMS threshold as the production PCM speech-edge detector. Pure
/// silence is marked unvoiced so a retained caption during a pause is harmless.
private func readingLeadActivity(_ pcm: Data) -> (start: Int64, end: Int64, voiced: Bool) {
    let window = 240
    let energies: [Double] = pcm.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        return stride(from: 0, to: pcm.count / 2, by: window).compactMap { start in
            guard start + window <= pcm.count / 2 else { return nil }
            var total = 0.0
            for index in start..<(start + window) {
                let word = UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8
                let value = Double(Int16(bitPattern: word))
                total += value * value
            }
            return total / Double(window)
        }
    }
    let peak = sqrt(energies.max() ?? 0), threshold = max(32.0, peak * 0.03)
    let active = energies.indices.filter { energies[$0] >= threshold * threshold }
    guard let first = active.first, let last = active.last else {
        return (0, Int64(pcm.count / 2), false)
    }
    return (Int64(first * window), Int64(min((last + 1) * window, pcm.count / 2)), true)
}

@MainActor private final class ReadingReplayApplication: NSObject, NSApplicationDelegate {
    var failure: Error?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await NativeReadingLeadReplay.replay() }
            catch { failure = error }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if !NATIVE_READING_UI_CHECKS
@main
#endif
struct NativeReadingLeadReplay {
    @MainActor static func main() throws {
        let app = NSApplication.shared, delegate = ReadingReplayApplication()
        app.setActivationPolicy(.prohibited)
        app.delegate = delegate
        app.run()
        if let failure = delegate.failure { throw failure }
    }

    @MainActor static func replay() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 6 else {
            throw ServiceError.message("Usage: NativeReadingLeadReplay ROOT PCM16_16KHZ_MONO DIRECTION REPORT_JSON OUTPUT_UID")
        }
        let reportURL = URL(fileURLWithPath: arguments[4])
        func write(_ report: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        let pcm: Data
        do {
            pcm = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            guard pcm.count >= 10 * 32000, pcm.count % 2 == 0, arguments[5] != "none" else {
                throw ServiceError.message("Provide at least 10 seconds of raw mono PCM16 at 16 kHz and a playback output UID")
            }
        } catch {
            try write(["direction": arguments[3], "input": arguments[2],
                       "source_complete": false, "error": error.localizedDescription])
            throw error
        }
        let capture = ReadingLeadFileCapture(pcm: pcm), session = NativeSession(capture: capture)
        let outputProbe = NativeSpeechOutputProbe()
        let overlay = SubtitleOverlayController(), meter = NSLevelIndicator()
        var style = SubtitlePreferences.load(from: UserDefaults(suiteName: "org.pccs.voxbridge.console") ?? .standard)
        style.mode = .reading; style.enabled = true
        style.fontName = "PingFangSC-Semibold"; style.fontSize = 30
        guard let screen = SubtitleDisplays.selected(style.screenID) else {
            throw ServiceError.message("No screen is available for native caption rendering")
        }
        let screenFrame = screen.frame
        session.configureReadingPresentation(splitter: { text in
            SubtitleTextLayout.layout(text: text, preferences: style, screen: screenFrame)?.pages ?? [text]
        }, fits: { text in
            SubtitleTextLayout.layout(text: text, preferences: style, screen: screenFrame)?.pages.count == 1
        }, liveSplitter: { text in
            SubtitleTextLayout.layout(text: text, preferences: style, screen: screenFrame, fitCompleteText: true)?.pages ?? [text]
        }, liveFits: { text in
            SubtitleTextLayout.layout(text: text, preferences: style, screen: screenFrame, fitCompleteText: true)?.pages.count == 1
        })
        overlay.apply(preferences: style)
        var preferences = NativePreferences()
        preferences.direction = arguments[3]; preferences.outputUID = arguments[5]
        session.subtitleMode = .reading
        let sourceSeconds = Double(pcm.count) / 32000
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + sourceSeconds + 240
        var chunks: [Int: NativeSpeechChunk] = [:], chunkEvents: [[String: Any]] = []
        var schedule: [Int: [String: Any]] = [:]
        var activity: [Int: (start: Int64, end: Int64, voiced: Bool)] = [:]
        var snapshots: [[String: Any]] = [], captions: [[String: Any]] = []
        var paints: [[String: Any]] = [], reusedPaintBindings: [[String: Any]] = [], lastScreenPaint: [String: Any]?
        var pageAnchors: [String: [String: Any]] = [:]
        var paintClipping: [[String: Any]] = [], drawnIdentities = Set<String>()
        var selectedTimes: [String: Double] = [:], drawLatencies: [Double] = []
        var overlayUpdates = 0, meterUpdates = 0
        var firstAppearances: [Int: [String: Any]] = [:], violations: [[String: Any]] = []
        var expectedLeadTransitions: [[String: Any]] = []
        var voicedSamples: [Int: Int] = [:], coveredSamples: [Int: Int] = [:]
        var previousText = "", previousID = "", previousRevision = -1, previousSequence = -1
        var previousLive = false, lastViolationKey = ""
        var beforeStopHistory: [[String: Any]] = [], lastPlayback: [String: Any] = [:]
        var errorMessage = "", runFinished = false, timedOut = false

        func collectPageAnchors(_ diagnostics: [String: Any]) {
            for reference in diagnostics["reading_references"] as? [[String: Any]] ?? [] {
                guard let sequence = readingLeadReferenceSequence(reference),
                      let page = readingLeadInteger(reference["page"]) else { continue }
                pageAnchors["\(sequence):\(page)"] = reference
            }
        }
        func recordVisibility(_ snapshot: [String: Any], physicalDraw: Bool) {
            lastScreenPaint = snapshot
            let id = snapshot["reading_sentence_id"] as? String ?? ""
            if !id.isEmpty, drawnIdentities.insert(id).inserted, physicalDraw,
               let selected = selectedTimes[id], let painted = snapshot["paint_uptime"] as? Double {
                drawLatencies.append((painted - selected) * 1000)
            }
            let full = snapshot["reading_text"] as? String ?? ""
            if readingLeadCompact(snapshot["visible_text"] as? String ?? "") != readingLeadCompact(full) {
                paintClipping.append(snapshot)
            }
            for reference in snapshot["reading_references"] as? [[String: Any]] ?? [] {
                guard let sequence = readingLeadReferenceSequence(reference), sequence > 0,
                      firstAppearances[sequence] == nil else { continue }
                var appearance = snapshot
                appearance["occurrence_first_sequence"] = sequence
                appearance["occurrence_reference"] = reference
                if let start = readingLeadReferenceStart(reference) { appearance["start_frame"] = start }
                firstAppearances[sequence] = appearance
            }
        }
        session.onChange = {
            overlayUpdates += 1
            if let id = session.subtitleIdentity?.sentenceID, selectedTimes[id] == nil {
                selectedTimes[id] = ProcessInfo.processInfo.systemUptime
            }
            let active = session.phase == .running || session.phase == .stopping || !session.subtitleText.isEmpty
            overlay.setLiveText(session.subtitleText, identity: session.subtitleIdentity,
                                synchronized: session.subtitleFollowsPlayback,
                                readingManaged: session.readingModeEnabled, active: active)
            let diagnostics = session.playbackDiagnostics
            collectPageAnchors(diagnostics)
            if let paint = lastScreenPaint, let rebound = nativeReadingRebindUnchangedPaint(
                paint, diagnostics: diagnostics, uptime: ProcessInfo.processInfo.systemUptime) {
                reusedPaintBindings.append(rebound)
                recordVisibility(rebound, physicalDraw: false)
            }
        }
        session.onLevelChange = { value in
            meterUpdates += 1; meter.doubleValue = Double(min(1, value * 3))
        }
        session.onPlaybackSchedule = { outputProbe.observeSchedule($0) }
        session.onPlaybackMixerOutput = { buffer, time in outputProbe.observeMixer(buffer, time) }
        // Flood the actual meter-only callback before starting any producer.
        // A regression would invalidate the whole caption path 10,000 times.
        let beforeFlood = overlayUpdates
        for index in 0..<10_000 { session.observeLevelForTesting(Float(index % 100) / 100) }
        let levelFloodRenderCount = overlayUpdates - beforeFlood
        guard levelFloodRenderCount == 0, meterUpdates == 10_000 else {
            throw ServiceError.message("Capture level events invalidated the full caption UI")
        }
        overlay.textView.onDidDraw = { paint in
            var snapshot = session.playbackDiagnostics
            snapshot["elapsed"] = paint.uptime - began
            snapshot["paint_uptime"] = paint.uptime
            snapshot["presented_frame"] = snapshot["subtitle_presented_frame"] ?? NSNull()
            snapshot["painted_text"] = paint.text; snapshot["visible_text"] = paint.visibleText
            snapshot["screen_drawing"] = paint.isScreenDrawing
            snapshot["window_visible"] = paint.windowVisible
            snapshot["forced_offscreen"] = paint.forcedOffscreen
            let id = snapshot["reading_sentence_id"] as? String ?? ""
            if let selected = selectedTimes[id] {
                snapshot["selected_uptime"] = selected
                snapshot["selected_to_draw_ms"] = (paint.uptime - selected) * 1000
            }
            paints.append(snapshot)
            guard paint.isScreenDrawing, paint.windowVisible, !paint.forcedOffscreen else { return }
            collectPageAnchors(snapshot)
            recordVisibility(snapshot, physicalDraw: true)
        }

        func history() -> [[String: Any]] {
            session.subtitleHistory.entries.map {
                ["id": $0.id, "revision": $0.revision, "source": $0.source, "translation": $0.translation]
            }
        }
        func collectSchedule(_ diagnostics: [String: Any]) {
            for item in diagnostics["pcm_chunks"] as? [[String: Any]] ?? [] {
                if let sequence = readingLeadInteger(item["seq"]) { schedule[Int(sequence)] = item }
            }
        }
        session.onPlaybackPCM = { chunk in
            outputProbe.observePCM(chunk)
            let diagnostics = session.playbackDiagnostics
            collectSchedule(diagnostics)
            chunks[chunk.seq] = chunk; activity[chunk.seq] = readingLeadActivity(chunk.pcm)
            chunkEvents.append(["elapsed": ProcessInfo.processInfo.systemUptime - began,
                "seq": chunk.seq, "sentence_id": chunk.sentence_id, "revision": chunk.revision,
                "source_order": chunk.source_order, "index": chunk.index, "count": chunk.count,
                "text": chunk.text, "bytes": chunk.pcm.count, "duration_ms": chunk.duration_ms,
                "sample_rate": chunk.sample_rate, "tts_speed": session.speed,
                "accepted_rendered_frame": diagnostics["rendered_frame"] ?? NSNull(),
                "accepted_presented_frame": diagnostics["subtitle_presented_frame"] ?? NSNull(),
                "sha256": SHA256.hash(data: chunk.pcm).map { String(format: "%02x", $0) }.joined()])
        }
        func observe() {
            let diagnostics = session.playbackDiagnostics
            collectSchedule(diagnostics)
            collectPageAnchors(diagnostics)
            if diagnostics["mode"] as? String == "pcm" { lastPlayback = diagnostics }
            let now = ProcessInfo.processInfo.systemUptime - began
            let frame = readingLeadInteger(diagnostics["subtitle_presented_frame"])
            let text = diagnostics["reading_text"] as? String ?? session.subtitleText
            let id = diagnostics["reading_sentence_id"] as? String ?? ""
            let revision = Int(readingLeadInteger(diagnostics["reading_revision"]) ?? 0)
            let sequence = Int(readingLeadInteger(diagnostics["reading_sequence"]) ?? 0)
            let live = diagnostics["reading_live"] as? Bool ?? false
            let references = diagnostics["reading_references"] as? [[String: Any]] ?? []
            let targetFrame = readingLeadInteger(diagnostics["reading_target_frame"])
            let visibleText = lastScreenPaint?["visible_text"] as? String ?? ""
            let visibleReferences = lastScreenPaint?["reading_references"] as? [[String: Any]] ?? []
            let visibleTarget = readingLeadInteger(lastScreenPaint?["reading_target_frame"])
            var snapshot: [String: Any] = ["elapsed": now, "phase": session.phase.rawValue,
                "reading_live": live, "reading_text": text, "reading_sentence_id": id,
                "reading_revision": revision, "reading_sequence": sequence, "tts_speed": session.speed,
                "reading_references": references,
                "reading_target_frame": targetFrame.map { $0 as Any } ?? NSNull(),
                "overlay_visible_text": visibleText,
                "last_screen_paint_uptime": lastScreenPaint?["paint_uptime"] ?? NSNull(),
                "rendered_frame": diagnostics["rendered_frame"] ?? NSNull(),
                "presented_frame": frame.map { $0 as Any } ?? NSNull(),
                "history_count": diagnostics["history_count"] ?? session.subtitleHistory.entries.count,
                "received_seq": diagnostics["received_seq"] ?? NSNull(),
                "played_seq": diagnostics["played_seq"] ?? NSNull(),
                "buffered_ms": diagnostics["buffered_ms"] ?? NSNull()]
            if text != previousText || id != previousID || revision != previousRevision ||
                sequence != previousSequence || live != previousLive {
                captions.append(snapshot)
                previousText = text; previousID = id; previousRevision = revision
                previousSequence = sequence; previousLive = live
            }
            let ordered = schedule.keys.sorted().compactMap { schedule[$0] }
            if let frame, let current = SubtitlePlayback.pcm(ordered, presentedFrame: frame),
               let seq = current.identity.speechSequence, let timing = schedule[seq],
               let start = readingLeadInteger(timing["start_frame"]), let bounds = activity[seq],
               bounds.voiced, frame >= start + bounds.start, frame < start + bounds.end {
                let covered = readingLeadCompact(visibleText).contains(readingLeadCompact(current.text))
                let occurrenceMatches = visibleReferences.contains { readingLeadReferenceMatches($0, timing: timing) }
                let classification = nativeReadingPaintCoverage(frame: frame, timing: timing, chunkText: current.text,
                    visibleText: visibleText, visibleReferences: visibleReferences, expectedReferences: Array(pageAnchors.values),
                    visibleTarget: visibleTarget)
                let validCoverage = classification == "covered_current_occurrence" || classification == "covered_current_physical_page"
                voicedSamples[seq, default: 0] += 1
                if validCoverage { coveredSamples[seq, default: 0] += 1 }
                snapshot["spoken_sequence"] = seq
                snapshot["spoken_sentence_id"] = current.identity.sentenceID
                snapshot["spoken_revision"] = current.identity.revision
                snapshot["spoken_text"] = current.text
                snapshot["reading_contains_spoken_chunk"] = covered
                snapshot["reading_references_match_spoken_occurrence"] = occurrenceMatches
                snapshot["coverage_classification"] = classification
                if classification == "lagging_past_occurrence" || classification == "lagging_past_page" {
                    snapshot["past_occurrence_lag_frames"] = frame - start
                }
                let key = "\(seq):\(sequence):\(id):\(revision):\(visibleText)"
                if classification == "expected_lead_transition", key != lastViolationKey {
                    expectedLeadTransitions.append(snapshot); lastViolationKey = key
                } else if !validCoverage, key != lastViolationKey {
                    violations.append(snapshot); lastViolationKey = key
                } else if validCoverage { lastViolationKey = "" }
            }
            snapshots.append(snapshot)
        }
        let run = Task { @MainActor in
            do {
                try await session.start(preferences: preferences, root: URL(fileURLWithPath: arguments[1]))
                while !capture.finished, session.phase == .running, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                beforeStopHistory = history()
                let complete = capture.finished && capture.sentBytes == pcm.count
                if !complete { errorMessage = session.lastError ?? "source was interrupted" }
                await session.stop(drain: complete)
                if let error = session.lastError { errorMessage = error }
            } catch {
                errorMessage = error.localizedDescription
                beforeStopHistory = history()
                await session.stop(drain: false)
            }
            runFinished = true
        }
        while !runFinished {
            // NSApplication.run drives ordinary visible-window painting while
            // this task sleeps; never substitute forced bitmap drawing.
            observe()
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true; errorMessage = "replay exceeded source duration plus 240 seconds"
                run.cancel(); await capture.stop()
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        NSApp.updateWindows(); observe(); session.onPlaybackPCM = nil
        session.onChange = nil; session.onLevelChange = nil
        session.onPlaybackSchedule = nil; session.onPlaybackMixerOutput = nil
        overlay.textView.onDidDraw = nil; overlay.close()
        let afterStopHistory = history()
        let retained = !afterStopHistory.isEmpty && beforeStopHistory.allSatisfy { old in
            afterStopHistory.contains { row in
                row["id"] as? String == old["id"] as? String &&
                    (row["revision"] as? Int ?? -1) >= (old["revision"] as? Int ?? 0)
            }
        }
        let orderedSchedule = schedule.keys.sorted().compactMap { schedule[$0] }
        let chunkReports: [[String: Any]] = chunkEvents.map { event in
            var result = event
            let seq = Int(readingLeadInteger(event["seq"])!)
            if let timing = schedule[seq] {
                result["schedule"] = timing
                if let start = readingLeadInteger(timing["start_frame"]),
                   let end = readingLeadInteger(timing["end_frame"]), let chunk = chunks[seq] {
                    result["pcm_frame_count_matches"] = end - start == Int64(chunk.pcm.count / 2)
                    if let bounds = activity[seq] {
                        result["voiced"] = bounds.voiced
                        result["speech_start_frame"] = start + bounds.start
                        result["speech_end_frame"] = start + bounds.end
                    }
                }
            }
            result["voiced_samples"] = voicedSamples[seq, default: 0]
            result["covered_voiced_samples"] = coveredSamples[seq, default: 0]
            return result
        }
        let appearanceReports: [[String: Any]] = firstAppearances.keys.sorted().map { sequence in
            var appearance = firstAppearances[sequence]!
            let start = readingLeadInteger(appearance["start_frame"]) ?? readingLeadInteger(schedule[sequence]?["start_frame"])
            if let start {
                appearance["start_frame"] = start
                // -1 is the production diagnostic's unavailable-clock sentinel.
                if let frame = readingLeadInteger(appearance["presented_frame"]), frame != -1 {
                    appearance["lead_frames"] = start - frame
                    appearance["lead_ms"] = Double(start - frame) / 24
                    if let bounds = activity[sequence], bounds.voiced {
                        let voiceLead = start + bounds.start - frame
                        appearance["rms_voice_lead_ms"] = Double(voiceLead) / 24
                        appearance["draw_leads_rms_voice_onset"] = voiceLead >= 0
                    }
                }
            }
            return appearance
        }
        let gaps: [[String: Any]] = zip(orderedSchedule, orderedSchedule.dropFirst()).compactMap { previous, next in
            guard let end = readingLeadInteger(previous["end_frame"]),
                  let start = readingLeadInteger(next["start_frame"]) else { return nil }
            return ["previous_seq": previous["seq"]!, "next_seq": next["seq"]!,
                    "gap_frames": start - end, "gap_ms": Double(start - end) / 24]
        }
        let sourceComplete = capture.finished && capture.sentBytes == pcm.count
        if errorMessage.isEmpty, chunks.isEmpty { errorMessage = "no synthesized PCM" }
        if errorMessage.isEmpty, !retained { errorMessage = "completed translation history was not retained after stop" }
        let frameLengthsPreserved = chunkReports.allSatisfy { $0["pcm_frame_count_matches"] as? Bool == true }
        if errorMessage.isEmpty, !frameLengthsPreserved { errorMessage = "scheduled frame spans differ from accepted PCM lengths" }
        if errorMessage.isEmpty, lastScreenPaint == nil { errorMessage = "no AppKit screen paint was observed" }
        if errorMessage.isEmpty, !paintClipping.isEmpty { errorMessage = "an overlay paint clipped its accepted reading card" }
        if errorMessage.isEmpty, !violations.isEmpty { errorMessage = "unexpected past or missing painted caption coverage" }
        let rmsLeads = appearanceReports.compactMap { $0["rms_voice_lead_ms"] as? Double }
        if errorMessage.isEmpty, rmsLeads.contains(where: { $0 < -50 }) { errorMessage = "an initial screen paint lagged RMS voice onset by more than 50 ms" }
        let sortedDrawLatencies = drawLatencies.sorted()
        var outputReport: [String: Any] = [:]
        do {
            let directory = reportURL.deletingLastPathComponent().appendingPathComponent(
                reportURL.deletingPathExtension().lastPathComponent + "-software-output", isDirectory: true)
            outputReport = try outputProbe.writeArtifacts(to: directory)
        } catch {
            outputReport = ["error": error.localizedDescription]
            if errorMessage.isEmpty { errorMessage = "software output probe failed: \(error.localizedDescription)" }
        }
        try write(["direction": arguments[3], "input": arguments[2], "output_uid": arguments[5],
            "source_seconds": sourceSeconds, "sent_source_seconds": Double(capture.sentBytes) / 32000,
            "source_complete": sourceComplete, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began,
            "poll_interval_ms": 20, "time_cap_seconds": sourceSeconds + 240, "timed_out": timedOut,
            "phase": session.phase.rawValue, "error": errorMessage, "chunks": chunkReports,
            "received_order": chunkEvents.compactMap { $0["seq"] as? Int },
            "schedule": orderedSchedule, "schedule_gaps": gaps, "last_playback": lastPlayback,
            "captions": captions, "first_appearances": appearanceReports, "snapshots": snapshots,
            "overlay_paints": paints, "overlay_paint_clipping": paintClipping,
            "reused_paint_bindings": reusedPaintBindings, "reading_page_anchors": Array(pageAnchors.values),
            "unpainted_caption_identities": Set(captions.compactMap { $0["reading_sentence_id"] as? String }.filter { !$0.isEmpty }).subtracting(drawnIdentities).sorted(),
            "layout": ["font_name": style.fontName, "font_size": style.fontSize,
                       "width_fraction": style.widthFraction, "screen_width": screenFrame.width, "screen_height": screenFrame.height],
            "level_flood_events": 10_000, "level_flood_full_render_count": levelFloodRenderCount,
            "meter_update_count": meterUpdates, "overlay_update_count": overlayUpdates,
            "selected_to_draw_max_ms": sortedDrawLatencies.last.map { $0 as Any } ?? NSNull(),
            "selected_to_draw_p95_ms": sortedDrawLatencies.isEmpty ? NSNull() : sortedDrawLatencies[max(0, Int(ceil(Double(sortedDrawLatencies.count) * 0.95)) - 1)] as Any,
            "negative_rms_voice_lead_count": rmsLeads.filter { $0 < 0 }.count,
            "minimum_rms_voice_lead_ms": rmsLeads.min().map { $0 as Any } ?? NSNull(),
            "software_output_probe": outputReport,
            "voiced_caption_coverage_violations": violations,
            "expected_lead_transitions": expectedLeadTransitions,
            "history_before_stop": beforeStopHistory, "history_after_stop": afterStopHistory,
            "history_retained": retained, "pcm_frame_lengths_preserved": frameLengthsPreserved,
            "limitations": ["Presentation progress is polled every 20 ms; this is not a physical output recording.",
                "First appearance lead uses AppKit on-screen draw callbacks, only when the presentation clock is available.",
                "AppKit draw completion is not a physical display/compositor or speaker recording.",
                "Identical complete visible text may reuse pixels; those identity bindings retain the previous physical paint time and are reported separately.",
                "Long-chunk page anchors are approximate PCM/text-work positions, without word alignment.",
                "Occurrence matching uses reading references; text coverage ignores whitespace and accepts grouped whole sentences.",
                "An upcoming occurrence within the 600 ms lead window is reported separately from actual lag or partial pagination, without aborting.",
                "A hard time-cap failure writes the report and exits; process teardown releases the native audio engine."]])
        guard errorMessage.isEmpty, sourceComplete, session.phase == .idle else {
            throw ServiceError.message(errorMessage.isEmpty ? "replay did not finish in idle state" : errorMessage)
        }
        print("PASS: \(arguments[3]), \(chunks.count) PCM chunks, \(captions.count) caption changes, \(violations.count) reported coverage mismatches, retained history \(afterStopHistory.count)")
    }
}
