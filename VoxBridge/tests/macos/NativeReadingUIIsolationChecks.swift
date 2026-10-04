import AppKit
import Foundation

@MainActor private final class MeterOnlyCapture: NativeAudioSource {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    func start(inputUID: String) async throws { fatalError("This UI check must never start a producer") }
    func stop() async {}
}

@main struct NativeReadingUIIsolationChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let session = NativeSession(capture: MeterOnlyCapture()), meter = NSLevelIndicator()
        var renders = 0, meterEvents = 0
        session.onChange = { renders += 1 }
        session.onLevelChange = { value in
            meterEvents += 1; meter.doubleValue = Double(min(1, value * 3))
        }
        for _ in 0..<10_000 { session.observeLevelForTesting(0.25) }
        assert(renders == 0 && meterEvents == 10_000 && meter.doubleValue == 0.75,
               "Capture level floods must update only the meter, without invalidating captions or history")
        let timing: [String: Any] = ["sentence_id": "current", "revision": 1, "source_order": 2]
        func reference(page: Int, start: Int64, order: Int = 2, id: String = "current") -> [String: Any] {
            ["sentence_id": id, "revision": 1, "source_order": order, "first_sequence": 3, "page": page, "start_frame": start]
        }
        let first = reference(page: 0, start: 0), second = reference(page: 1, start: 24_000)
        func coverage(_ frame: Int64, _ painted: [String: Any], _ target: Int64 = 0) -> String {
            nativeReadingPaintCoverage(frame: frame, timing: timing, chunkText: "A whole long chunk.",
                visibleText: "A physical page.", visibleReferences: [painted], expectedReferences: [second], visibleTarget: target)
        }
        assert(coverage(23_999, first) == "covered_current_physical_page", "Whole-chunk containment is invalid for real physical pages")
        assert(coverage(24_000, first) == "lagging_past_page", "A past painted page beyond its PCM anchor must fail")
        assert(coverage(24_000, second, 24_000) == "covered_current_physical_page")
        assert(coverage(23_000, reference(page: 0, start: 24_000, order: 3, id: "next"), 24_000) == "expected_lead_transition")
        assert(coverage(24_000, reference(page: 0, start: 0, order: 1, id: "past")) == "lagging_past_occurrence")
        assert(coverage(24_000, reference(page: 0, start: 0, order: 2, id: "wrong")) == "missing_current_occurrence")
        assert(coverage(0, second, 24_000) == "premature_page")
        let third = reference(page: 2, start: 48_000)
        assert(nativeReadingPaintCoverage(frame: 30_000, timing: timing, chunkText: "A whole long chunk.",
            visibleText: "A physical page.", visibleReferences: [first], expectedReferences: [first, second, third],
            visibleTarget: 0) == "lagging_past_page", "An early selection of a later page must not discard the intermediate due-page anchor")
        let priorPaint: [String: Any] = ["reading_sentence_id": "old", "painted_text": "Repeated sentence.",
            "visible_text": "Repeated sentence.", "paint_uptime": 1.0]
        let nextRepeated: [String: Any] = ["reading_sentence_id": "new", "reading_text": "Repeated sentence.",
            "subtitle_presented_frame": 24_000, "reading_references": [reference(page: 0, start: 24_000, order: 3, id: "next")]]
        let rebound = nativeReadingRebindUnchangedPaint(priorPaint, diagnostics: nextRepeated, uptime: 2.0)!
        assert(rebound["reading_sentence_id"] as? String == "new" && rebound["paint_uptime"] as? Double == 1.0 &&
               rebound["visibility_binding_uptime"] as? Double == 2.0 && rebound["presented_frame"] as? Int == 24_000 &&
               rebound["pixel_reuse"] as? Bool == true, "An identical occurrence can reuse visible pixels without inventing a new draw")
        var clippedPaint = priorPaint; clippedPaint["visible_text"] = "Repeated"
        assert(nativeReadingRebindUnchangedPaint(clippedPaint, diagnostics: nextRepeated, uptime: 2.0) == nil,
               "Partial text must never be rebound as complete visible pixels")
        var changedText = nextRepeated; changedText["reading_text"] = "Changed sentence."
        assert(nativeReadingRebindUnchangedPaint(priorPaint, diagnostics: changedText, uptime: 2.0) == nil)

        let console = AppDelegate()
        let consoleText = (0..<250).map { "completeword\($0)" }.joined(separator: " ") + " FINAL_VISIBLE_TAIL."
        let (consoleWindow, translationField, consoleScroll) = console.consoleTranslationLayoutForTesting(text: consoleText)
        assert(!consoleWindow.isVisible && translationField.stringValue == consoleText)
        assert(translationField.maximumNumberOfLines == 0 && translationField.lineBreakMode == .byWordWrapping)
        let drawingBounds = translationField.cell!.drawingRect(forBounds: translationField.bounds)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = translationField.lineBreakMode
        let storage = NSTextStorage(string: consoleText, attributes: [.font: translationField.font!, .paragraphStyle: paragraph])
        let manager = NSLayoutManager(), container = NSTextContainer(containerSize: drawingBounds.size)
        container.lineFragmentPadding = 0; manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let laidOutCharacters = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
        assert(NSMaxRange(laidOutCharacters) == (consoleText as NSString).length,
               "The real console translation field clipped the final characters")
        assert(translationField.frame.height > translationField.font!.boundingRectForFont.height * 3 &&
               consoleScroll.documentView!.frame.height > consoleScroll.contentView.bounds.height,
               "Complete translation cards must grow the existing scroll document beyond three lines")
        consoleWindow.close()

        guard let screen = NSScreen.screens.first else { fatalError("No display for real caption geometry") }
        let english = (0..<600).map { "readingword\($0)" }.joined(separator: " ") + "."
        let chinese = String(repeating: "完整译文必须保留所有字符并跟随已接受音频的进度。", count: 80)
        for (language, text) in [("en", english), ("zh", chinese)] {
            for size in [30.0, 72.0] {
                var style = SubtitlePreferences()
                style.fontName = "PingFangSC-Semibold"; style.fontSize = size
                style.enabled = false // This deterministic geometry test stays offscreen.
                style.widthFraction = 0.8
                let layout = SubtitleTextLayout.layout(text: text, preferences: style, screen: screen.frame, fitCompleteText: true)!
                assert(layout.pages.count > 1 && layout.preferences.fontSize == size)
                var reader = LiveReadingSubtitle(); reader.reset(targetLanguage: language)
                reader.configure(splitter: {
                    SubtitleTextLayout.layout(text: $0, preferences: style, screen: screen.frame, fitCompleteText: true)!.pages
                }, fits: {
                    SubtitleTextLayout.layout(text: $0, preferences: style, screen: screen.frame, fitCompleteText: true)!.pages.count == 1
                })
                reader.accept([["seq": 1, "sentence_id": "long-\(language)", "revision": 1, "source_order": 0,
                                "index": 0, "count": 1, "start_frame": Int64(0), "end_frame": Int64(2_880_000),
                                "text": text, "sentence_text": text]])
                let overlay = SubtitleOverlayController(); overlay.apply(preferences: style)
                var shown: [String] = []
                for frame in stride(from: -LiveReadingSubtitle.leadFrames, through: Int64(2_880_000), by: 1_200) {
                    guard reader.advance(presentedFrame: frame), let caption = reader.caption else { continue }
                    shown.append(caption.text)
                    assert(!caption.text.contains(where: { $0.isNewline }))
                    overlay.setLiveText(caption.text, identity: caption.identity, readingManaged: true, active: true)
                    let bitmap = overlay.textView.bitmapImageRepForCachingDisplay(in: overlay.textView.bounds)!
                    overlay.textView.forceOffscreenObservationForTesting = true
                    overlay.textView.cacheDisplay(in: overlay.textView.bounds, to: bitmap)
                    overlay.textView.forceOffscreenObservationForTesting = false
                    guard let paint = overlay.textView.lastPaintForTesting else { fatalError("No CoreText draw captured") }
                    assert(paint.forcedOffscreen && !paint.windowVisible,
                           "Forced bitmap drawing must be explicitly labeled and excluded from visible screen timing")
                    assert(paint.text == caption.text && paint.visibleText == caption.text,
                           "Re-layout of a live page clipped its tail or silently produced multiple overlay pages")
                }
                assert(shown.count == layout.pages.count, "Long live sentences dropped a final physical page")
                assert(String(shown.joined().filter { !$0.isWhitespace }) == String(text.filter { !$0.isWhitespace }),
                       "Actual font/screen pagination omitted or reordered long-sentence content")
                assert(shown.last == SubtitlePresentation.singleLine(layout.pages.last!))
                overlay.close()
            }
        }
        print("PASS: meter-only flood, real PingFang/font/screen paging, every long-page glyph including final pages; offscreen draws explicitly labeled")
    }
}
