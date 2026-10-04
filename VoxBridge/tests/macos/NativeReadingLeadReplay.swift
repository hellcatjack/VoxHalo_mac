import Foundation
import AppKit
import CryptoKit

/// Standalone acceptance harness, compiled with -D NATIVE_PLAYBACK_TESTING and
/// the production native App sources. Run only after its current producer stops:
/// NativeReadingLeadReplay ROOT PCM16_16KHZ_MONO DIRECTION REPORT_JSON OUTPUT_UID
/// Input must contain at least 10 seconds. This uses real ASR/MT/TTS and audible
/// native output; it creates no overlay and saves no preferences. Reports use the
/// presentation clock, not a physical recording of the speaker or the screen.
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

@main struct NativeReadingLeadReplay {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
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
        var preferences = NativePreferences()
        preferences.direction = arguments[3]; preferences.outputUID = arguments[5]
        session.subtitleMode = .reading
        let sourceSeconds = Double(pcm.count) / 32000
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + sourceSeconds + 240
        var chunks: [Int: NativeSpeechChunk] = [:], chunkEvents: [[String: Any]] = []
        var schedule: [Int: [String: Any]] = [:]
        var activity: [Int: (start: Int64, end: Int64, voiced: Bool)] = [:]
        var snapshots: [[String: Any]] = [], captions: [[String: Any]] = []
        var firstAppearances: [Int: [String: Any]] = [:], violations: [[String: Any]] = []
        var expectedLeadTransitions: [[String: Any]] = []
        var voicedSamples: [Int: Int] = [:], coveredSamples: [Int: Int] = [:]
        var previousText = "", previousID = "", previousRevision = -1, previousSequence = -1
        var previousLive = false, lastViolationKey = ""
        var beforeStopHistory: [[String: Any]] = [], lastPlayback: [String: Any] = [:]
        var errorMessage = "", runFinished = false, timedOut = false

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
            let diagnostics = session.playbackDiagnostics
            collectSchedule(diagnostics)
            chunks[chunk.seq] = chunk; activity[chunk.seq] = readingLeadActivity(chunk.pcm)
            chunkEvents.append(["elapsed": ProcessInfo.processInfo.systemUptime - began,
                "seq": chunk.seq, "sentence_id": chunk.sentence_id, "revision": chunk.revision,
                "source_order": chunk.source_order, "index": chunk.index, "count": chunk.count,
                "text": chunk.text, "bytes": chunk.pcm.count, "duration_ms": chunk.duration_ms,
                "sample_rate": chunk.sample_rate,
                "accepted_rendered_frame": diagnostics["rendered_frame"] ?? NSNull(),
                "accepted_presented_frame": diagnostics["subtitle_presented_frame"] ?? NSNull(),
                "sha256": SHA256.hash(data: chunk.pcm).map { String(format: "%02x", $0) }.joined()])
        }
        func observe() {
            let diagnostics = session.playbackDiagnostics
            collectSchedule(diagnostics)
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
            var snapshot: [String: Any] = ["elapsed": now, "phase": session.phase.rawValue,
                "reading_live": live, "reading_text": text, "reading_sentence_id": id,
                "reading_revision": revision, "reading_sequence": sequence,
                "reading_references": references,
                "reading_target_frame": targetFrame.map { $0 as Any } ?? NSNull(),
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
            if live, !text.isEmpty {
                for reference in references {
                    guard let firstSequence = readingLeadReferenceSequence(reference), firstSequence > 0,
                          firstAppearances[firstSequence] == nil else { continue }
                    var appearance = snapshot
                    appearance["occurrence_first_sequence"] = firstSequence
                    appearance["occurrence_reference"] = reference
                    if let start = readingLeadReferenceStart(reference) { appearance["start_frame"] = start }
                    firstAppearances[firstSequence] = appearance
                }
                if references.isEmpty, sequence > 0, firstAppearances[sequence] == nil {
                    firstAppearances[sequence] = snapshot
                }
            }
            let ordered = schedule.keys.sorted().compactMap { schedule[$0] }
            if let frame, let current = SubtitlePlayback.pcm(ordered, presentedFrame: frame),
               let seq = current.identity.speechSequence, let timing = schedule[seq],
               let start = readingLeadInteger(timing["start_frame"]), let bounds = activity[seq],
               bounds.voiced, frame >= start + bounds.start, frame < start + bounds.end {
                let covered = readingLeadCompact(text).contains(readingLeadCompact(current.text))
                let occurrenceMatches = references.contains { readingLeadReferenceMatches($0, timing: timing) }
                let futureReferences = references.filter { reference in
                    guard let nextStart = readingLeadReferenceStart(reference), let targetFrame else { return false }
                    return nextStart > frame && nextStart <= targetFrame && nextStart - frame <= 14400
                }
                let pastReferences = references.filter { reference in
                    guard let prior = readingLeadInteger(reference["source_order"] ?? reference["sourceOrder"]),
                          let currentOrder = readingLeadInteger(timing["source_order"]) else { return false }
                    return prior < currentOrder
                }
                let classification: String
                if occurrenceMatches && covered { classification = "covered_current_occurrence" }
                else if !occurrenceMatches && !futureReferences.isEmpty { classification = "expected_lead_transition" }
                else if !occurrenceMatches && !pastReferences.isEmpty { classification = "lagging_past_occurrence" }
                else if occurrenceMatches { classification = "partial_current_page" }
                else if covered { classification = "matching_text_different_occurrence" }
                else { classification = "missing_current_occurrence" }
                voicedSamples[seq, default: 0] += 1
                if occurrenceMatches && covered { coveredSamples[seq, default: 0] += 1 }
                snapshot["spoken_sequence"] = seq
                snapshot["spoken_sentence_id"] = current.identity.sentenceID
                snapshot["spoken_revision"] = current.identity.revision
                snapshot["spoken_text"] = current.text
                snapshot["reading_contains_spoken_chunk"] = covered
                snapshot["reading_references_match_spoken_occurrence"] = occurrenceMatches
                snapshot["coverage_classification"] = classification
                if classification == "lagging_past_occurrence" { snapshot["past_occurrence_lag_frames"] = frame - start }
                let key = "\(seq):\(sequence):\(id):\(revision):\(text)"
                if classification == "expected_lead_transition", key != lastViolationKey {
                    expectedLeadTransitions.append(snapshot); lastViolationKey = key
                } else if classification != "covered_current_occurrence", key != lastViolationKey {
                    violations.append(snapshot); lastViolationKey = key
                } else if classification == "covered_current_occurrence" { lastViolationKey = "" }
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
            observe()
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true; errorMessage = "replay exceeded source duration plus 240 seconds"
                run.cancel(); await capture.stop()
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        observe(); session.onPlaybackPCM = nil
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
        try write(["direction": arguments[3], "input": arguments[2], "output_uid": arguments[5],
            "source_seconds": sourceSeconds, "sent_source_seconds": Double(capture.sentBytes) / 32000,
            "source_complete": sourceComplete, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began,
            "poll_interval_ms": 20, "time_cap_seconds": sourceSeconds + 240, "timed_out": timedOut,
            "phase": session.phase.rawValue, "error": errorMessage, "chunks": chunkReports,
            "received_order": chunkEvents.compactMap { $0["seq"] as? Int },
            "schedule": orderedSchedule, "schedule_gaps": gaps, "last_playback": lastPlayback,
            "captions": captions, "first_appearances": appearanceReports, "snapshots": snapshots,
            "voiced_caption_coverage_violations": violations,
            "expected_lead_transitions": expectedLeadTransitions,
            "history_before_stop": beforeStopHistory, "history_after_stop": afterStopHistory,
            "history_retained": retained, "pcm_frame_lengths_preserved": frameLengthsPreserved,
            "limitations": ["Presentation progress is polled every 20 ms; this is not a physical output recording.",
                "First appearance lead is measured only when the presentation clock is available.",
                "Occurrence matching uses reading references; text coverage ignores whitespace and accepts grouped whole sentences.",
                "An upcoming occurrence within the 600 ms lead window is reported separately from actual lag or partial pagination, without aborting.",
                "A hard time-cap failure writes the report and exits; process teardown releases the native audio engine."]])
        guard errorMessage.isEmpty, sourceComplete, session.phase == .idle else {
            throw ServiceError.message(errorMessage.isEmpty ? "replay did not finish in idle state" : errorMessage)
        }
        print("PASS: \(arguments[3]), \(chunks.count) PCM chunks, \(captions.count) caption changes, \(violations.count) reported coverage mismatches, retained history \(afterStopHistory.count)")
    }
}
