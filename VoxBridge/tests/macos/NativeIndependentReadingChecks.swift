import AppKit
import Foundation

/// Presentation checks use the real session, but never create a producer,
/// listener or output device. The injected times replace waiting on a wall clock.
@MainActor private final class NoAudioReadingCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func start(inputUID: String) async throws {
        starts += 1
        fatalError("Independent reading checks must never start an audio producer")
    }
    func stop() async { stops += 1 }
}

@MainActor private struct Fixture {
    let capture = NoAudioReadingCapture()
    let session: NativeSession
    init(_ direction: NativeTranslationDirection = .en2zh) {
        session = NativeSession(capture: capture, inputDevices: { [] }, outputDevices: { [] })
        var preferences = NativePreferences()
        preferences.direction = direction.rawValue
        // This is the normal spoken-output setting, not the output="none"
        // branch that already had an independent visual queue before this fix.
        preferences.outputUID = "default"
        session.resetIndependentReadingForTesting(preferences: preferences)
        session.subtitleMode = .reading
    }
    func source(_ id: String, at now: Double, revision: Int = 1) {
        session.observeReadingEventForTesting([
            "type": "sentence_committed", "sentence_id": id, "revision": revision,
            "text": "source-\(id)-\(revision)"
        ], now: now)
    }
    func translation(_ id: String, _ text: String, at now: Double, stable: Bool = true, revision: Int = 1) {
        session.observeReadingEventForTesting([
            "type": "sentence_translation", "sentence_id": id, "revision": revision,
            "translation": text, "is_stable": stable
        ], now: now)
    }
    func noAudio(_ context: String) {
        let diagnostics = session.playbackDiagnostics
        assert(capture.starts == 0 && capture.stops == 0 && session.playbackTime == 0,
               "Presentation touched producer/playback state: \(context)")
        assert((diagnostics["rate"] as? Float ?? 0) == 0 && diagnostics["pcm_chunks"] == nil,
               "Presentation created a PCM output schedule: \(context)")
    }
}

@MainActor private func completedTranslationWithoutPCM() {
    let fixture = Fixture(), session = fixture.session
    let first = "这是已经完成翻译的完整中文句子，字幕应该立即显示。"
    let second = "下一句译文已经完成，无需等待朗读结束或声卡继续前进。"
    var pcmCallbacks = 0, scheduleCallbacks = 0
    session.onPlaybackPCM = { _ in pcmCallbacks += 1 }
    session.onPlaybackSchedule = { _ in scheduleCallbacks += 1 }
    fixture.source("first", at: 100)
    fixture.translation("first", first, at: 100, stable: false)
    assert(!session.advanceIndependentReadingForTesting(now: 100) && session.subtitleText.isEmpty,
           "An incomplete translation was shown as a complete reading subtitle")
    fixture.translation("first", first, at: 100)
    assert(session.subtitleText == first,
           "A completed translation waited for nonexistent PCM or its confirmation gate")
    assert(!session.advanceIndependentReadingForTesting(now: 100),
           "The MT event should publish its reading page without a second timer tick")
    let identity = session.subtitleIdentity, deadline = session.independentReadingDeadlineForTesting
    assert(deadline >= 103 && !session.subtitleFollowsPlayback)
    fixture.noAudio("completed MT, zero PCM")
    fixture.source("second", at: 100.1)
    fixture.translation("second", second, at: 100.1)
    assert(!session.advanceIndependentReadingForTesting(now: 100.1))
    assert(!session.advanceIndependentReadingForTesting(now: deadline - 0.001))
    assert(session.subtitleText == first && session.subtitleIdentity == identity
           && session.independentReadingDeadlineForTesting == deadline,
           "A fresh translation replaced or moved words before the current page was read")
    assert(session.advanceIndependentReadingForTesting(now: deadline) && session.subtitleText == second,
           "A frozen audio playhead blocked the next readable translation")
    assert(session.subtitleIdentity != identity && pcmCallbacks == 0 && scheduleCallbacks == 0)
    fixture.noAudio("next page with the audio clock still zero")
}

@MainActor private func speechFeedbackDoesNotShortenReading() {
    for direction in [NativeTranslationDirection.en2zh, .zh2en] {
        let normal = Fixture(direction), fast = Fixture(direction)
        let text = direction == .en2zh
            ? "人工智能的进步需要清晰的沟通，也需要让听众有足够的时间完整阅读屏幕上的中文译文。"
            : "Accurate interpretation needs clear communication and enough time for people to read the complete translated sentence on the screen."
        for fixture in [normal, fast] {
            fixture.source("reading", at: 10)
        }
        // Fast/slow accepted speech durations used to alter the Chinese visual
        // clock. Reading mode must now keep the same target-language budget.
        for _ in 0..<12 {
            fast.session.observeReadingSpeechForTesting(text: text, seconds: 0.6)
            normal.session.observeReadingSpeechForTesting(text: text, seconds: 30)
        }
        for fixture in [normal, fast] {
            fixture.translation("reading", text, at: 10)
            assert(fixture.session.subtitleText == text)
        }
        let normalEnd = normal.session.independentReadingDeadlineForTesting
        let fastEnd = fast.session.independentReadingDeadlineForTesting
        assert(abs(normalEnd - fastEnd) < 0.001,
               "TTS playback speed changed the independent reading deadline for \(direction.rawValue)")
        assert(normalEnd > 13 && normal.session.subtitleText == fast.session.subtitleText)
        normal.noAudio("slow speech feedback")
        fast.noAudio("fast speech feedback")
    }
}

@MainActor private func hiddenCaptionsAndPlaybackMode() {
    let fixture = Fixture(), session = fixture.session
    let first = "隐藏或切换字幕模式时，不能修改朗读，也不能消耗用户尚未获得的阅读时间。"
    let second = "字幕重新开启以后，下一句仍按照独立的阅读时钟显示。"
    fixture.source("first", at: 100); fixture.translation("first", first, at: 100)
    assert(session.subtitleText == first)
    let identity = session.subtitleIdentity, deadline = session.independentReadingDeadlineForTesting
    fixture.source("second", at: 101); fixture.translation("second", second, at: 101)
    session.readingPresentationEnabled = false
    assert(!session.advanceIndependentReadingForTesting(now: 101))
    assert(!session.advanceIndependentReadingForTesting(now: 150))
    session.readingPresentationEnabled = true
    assert(!session.advanceIndependentReadingForTesting(now: 151))
    assert(session.subtitleText == first && session.subtitleIdentity == identity)
    let resumedEnd = session.independentReadingDeadlineForTesting
    assert(abs(resumedEnd - deadline - 50) < 0.001,
           "Hidden captions spent their reading budget while no text was visible")
    assert(session.advanceIndependentReadingForTesting(now: resumedEnd) && session.subtitleText == second)
    let secondEnd = session.independentReadingDeadlineForTesting
    session.subtitleMode = .playback
    assert(session.subtitleFollowsPlayback && session.subtitleText.isEmpty,
           "Playback mode used completed MT without any accepted audio")
    assert(!session.advanceIndependentReadingForTesting(now: resumedEnd + 1))
    fixture.noAudio("playback mode selection")
    session.subtitleMode = .reading
    assert(!session.advanceIndependentReadingForTesting(now: resumedEnd + 11))
    assert(session.subtitleText == second
           && abs(session.independentReadingDeadlineForTesting - secondEnd - 10) < 0.001)
    fixture.noAudio("return to reading mode")
}

@MainActor private func fontGeometryIsPresentationOnly() {
    let fixture = Fixture(), session = fixture.session
    let text = String(repeating: "字体只能由用户决定，字幕阅读不应该改变任何音频输出。", count: 8)
    fixture.source("geometry", at: 100); fixture.translation("geometry", text, at: 100)
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    for size in [36.0, 72.0] {
        var style = SubtitlePreferences(); style.fontSize = size
        session.configureReadingPresentation(splitter: {
            SubtitleTextLayout.layout(text: $0, preferences: style, screen: screen)!.pages
        }, fits: {
            SubtitleTextLayout.layout(text: $0, preferences: style, screen: screen)!.pages.count == 1
        })
        _ = session.advanceIndependentReadingForTesting(now: 100)
        guard !session.subtitleText.isEmpty else { fatalError("Font reconfiguration lost the visible text") }
        let layout = SubtitleTextLayout.layout(text: session.subtitleText, preferences: style, screen: screen,
                                             fitCompleteText: true)!
        assert(layout.preferences.fontSize == size && layout.pages.count == 1)
        assert(!session.subtitleText.contains(where: { $0.isNewline }))
        fixture.noAudio("manual font change to \(size)")
    }
}

@main struct NativeIndependentReadingChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        completedTranslationWithoutPCM()
        speechFeedbackDoesNotShortenReading()
        hiddenCaptionsAndPlaybackMode()
        fontGeometryIsPresentationOnly()
        print("PASS: completed MT without PCM, frozen playhead, independent reading duration, hidden/mode budget and fixed-font audio isolation")
    }
}
