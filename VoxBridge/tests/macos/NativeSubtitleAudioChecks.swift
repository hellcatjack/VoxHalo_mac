import Foundation
import AppKit
import CryptoKit

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

@main struct NativeSubtitleAudioChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 5 else { throw ServiceError.message("Usage: ROOT CHINESE_PCM ENGLISH_PCM REPORT") }
        let capture = DirectionReplayCapture(), root = URL(fileURLWithPath: CommandLine.arguments[1])
        let session = NativeSession(capture: capture), overlay = SubtitleOverlayController()
        var reports: [[String: Any]] = []
        for (pair, path) in [(NativeTranslationDirection.zh2en, CommandLine.arguments[2]), (.en2zh, CommandLine.arguments[3])] {
            capture.audio = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(13 * 32000)
            var preferences = NativePreferences(); preferences.direction = pair.rawValue; preferences.outputUID = "default"
            var captionEvents: [[String: Any]] = [], chunks: [NativeSpeechChunk] = [], last: CompletedSubtitleState.Identity?
            var schedule: [[String: Any]] = [], style = SubtitlePreferences(), sawQueuedFuture = false
            session.onPlaybackPCM = { chunks.append($0) }
            session.onChange = {
                let diagnostics = session.playbackDiagnostics
                if let recorded = diagnostics["pcm_chunks"] as? [[String: Any]], !recorded.isEmpty { schedule = recorded }
                let identity = session.subtitleIdentity
                guard identity != last else { return }; last = identity
                if let identity, let sequence = identity.speechSequence {
                    let audio = schedule.first { $0["seq"] as? Int == sequence }!
                    let frame = (diagnostics["subtitle_presented_frame"] as! NSNumber).int64Value
                    assert(frame >= (audio["start_frame"] as! NSNumber).int64Value, "caption led audible output")
                    assert(session.subtitleText == audio["text"] as? String, "caption diverged from the actual TTS text")
                    captionEvents.append(["seq": sequence, "text": session.subtitleText, "presented_frame": frame, "start_frame": audio["start_frame"]!])
                    print("CAPTION \(pair.rawValue) seq \(sequence): \(session.subtitleText)"); fflush(stdout)
                }
                overlay.setLiveText(session.subtitleText, identity: identity, synchronized: session.subtitleFollowsPlayback, active: session.isActive)
                overlay.panel.orderOut(nil)
            }
            try await session.start(preferences: preferences, root: root)
            do {
                let began = Date()
                var stopping = false, finished = false
                while !finished {
                    if capture.finished && !stopping {
                        stopping = true
                        Task { await session.stop(drain: true); finished = true }
                    }
                    guard Date().timeIntervalSince(began) < 110, session.lastError == nil else {
                        throw ServiceError.message(session.lastError ?? "test timed out")
                    }
                    if let seq = session.subtitleIdentity?.speechSequence,
                       let future = schedule.last?["seq"] as? Int, future > seq { sawQueuedFuture = true }
                    // Exercise appearance changes while audio plays. These do not
                    // call or feed back into any audio/synthesis method.
                    style.fontSize = style.fontSize == 36 ? 72 : 36
                    style.textColorHex = style.textColorHex == "#FFFFFF" ? "#FFE680" : "#FFFFFF"
                    style.verticalPosition = style.verticalPosition == 1 ? 0.5 : 1
                    overlay.apply(preferences: style); overlay.panel.orderOut(nil)
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                assert(session.phase == .idle && session.subtitleText.isEmpty)
                assert(!chunks.isEmpty && !captionEvents.isEmpty)
                assert(captionEvents.compactMap { $0["seq"] as? Int } == chunks.map(\.seq), "audio blocks were skipped by captions")
                assert(chunks.contains { $0.pcm.contains { $0 != 0 } })
                let chunkReports: [[String: Any]] = chunks.map { chunk in
                    let timing = schedule.first { $0["seq"] as? Int == chunk.seq }!
                    let start = (timing["start_frame"] as! NSNumber).int64Value, end = (timing["end_frame"] as! NSNumber).int64Value
                    assert(end - start == Int64(chunk.pcm.count / 2), "caption work changed scheduled audio length")
                    return ["seq": chunk.seq, "text": chunk.text, "start_frame": start, "end_frame": end,
                            "sha256": SHA256.hash(data: chunk.pcm).map { String(format: "%02x", $0) }.joined()]
                }
                reports.append(["direction": pair.rawValue, "captions": captionEvents, "chunks": chunkReports, "saw_queued_future": sawQueuedFuture])
                print("PASS \(pair.title): \(chunks.count) complete PCM chunks, \(captionEvents.count) playback captions, style changes during playback, full drain"); fflush(stdout)
            } catch { await session.stop(drain: false); overlay.close(); throw error }
        }
        overlay.close()
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
    }
}
