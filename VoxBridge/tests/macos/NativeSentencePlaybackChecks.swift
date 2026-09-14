import AppKit
import CoreText

/// Play a captured production Native PCM snapshot, including a whole Chinese
/// sentence and its queued successor. No ASR fixtures or browser are required.
@main struct NativeSentencePlaybackChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = try JSONDecoder().decode(NativeSpeechSnapshot.self, from: Data(contentsOf: input))
        assert(snapshot.chunks.count == 2 && snapshot.chunks[0].text.count >= 80)
        assert(snapshot.chunks.allSatisfy { $0.index == 0 && $0.count == 1 })
        let player = NativeSpeechPlayer(), overlay = SubtitleOverlayController()
        var failure: String?, events: [[String: Any]] = [], lastSequence: Int?
        player.onFailure = { failure = $0 }
        defer { player.stop(); overlay.close() }
        try player.start(outputUID: "default", epoch: snapshot.epoch, cursor: 0)
        try player.accept(snapshot)
        let schedule = player.scheduledChunks
        let firstEnd = (schedule[0]["end_frame"] as! NSNumber).int64Value
        assert(firstEnd == (schedule[1]["start_frame"] as! NSNumber).int64Value, "queued speech acquired an extra gap")
        for (chunk, timing) in zip(snapshot.chunks, schedule) {
            let frames = (timing["end_frame"] as! NSNumber).int64Value - (timing["start_frame"] as! NSNumber).int64Value
            assert(frames == chunk.pcm.count / 2, "PCM was truncated")
        }
        let began = Date()
        while !player.drained {
            guard Date().timeIntervalSince(began) < 50, failure == nil else {
                throw ServiceError.message(failure ?? "playback timed out")
            }
            if let frame = player.subtitlePresentedFrame,
               let caption = SubtitlePlayback.pcm(schedule, presentedFrame: frame) {
                let expected = frame < firstEnd ? snapshot.chunks[0] : snapshot.chunks[1]
                assert(caption.text == expected.text && caption.identity.speechSequence == expected.seq)
                var style = SubtitlePreferences(); style.fontSize = 144; style.widthFraction = 0.25
                style.verticalPosition = frame % 2 == 0 ? 1 : 0.5
                overlay.apply(preferences: style)
                overlay.setLiveText(caption.text, identity: caption.identity, synchronized: true, active: true)
                overlay.panel.orderOut(nil)
                assert(overlay.textView.accessibilityValue() as? String == expected.text)
                if lastSequence != expected.seq {
                    let layout = SubtitleTextLayout.layout(text: caption.text, preferences: style, screen: NSScreen.screens[0].frame, fitCompleteText: true)!
                    let padding = SubtitleTextLayout.padding(layout.preferences)
                    let setter = CTFramesetterCreateWithAttributedString(SubtitleTextLayout.attributed(caption.text, font: SubtitleTextLayout.font(layout.preferences)))
                    let path = CGPath(rect: CGRect(origin: .zero, size: CGSize(width: layout.frame.width - 2 * padding, height: layout.frame.height - 2 * padding)), transform: nil)
                    assert(CTFrameGetVisibleStringRange(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)).length == (caption.text as NSString).length)
                    events.append(["sequence": expected.seq, "presented_frame": frame, "text": caption.text])
                    lastSequence = expected.seq
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        assert(events.compactMap { $0["sequence"] as? Int } == snapshot.chunks.map(\.seq))
        assert(player.playedSequence == snapshot.cursor)
        let report: [String: Any] = ["captions": events, "schedule": schedule, "played_sequence": player.playedSequence, "elapsed_sec": Date().timeIntervalSince(began)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS: whole Chinese sentence held until its audio ended; next caption followed playback; no added scheduling gap; full PCM drain; complete text fits")
    }
}
