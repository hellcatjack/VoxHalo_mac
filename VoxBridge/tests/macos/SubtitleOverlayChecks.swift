import AppKit
import CoreText

@main struct SubtitleOverlayChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let screen = NSScreen.screens[0]
        var edge = SubtitlePreferences(); edge.verticalPosition = 1
        let edgeLayout = SubtitleTextLayout.layout(text: "字幕覆盖 Dock", preferences: edge, screen: screen.frame)!
        assert(edgeLayout.frame.minY == screen.frame.minY, "100% vertical must reach the physical bottom, including Dock")
        let font = NSFont.systemFont(ofSize: 36)
        for text in ["May the Lord bless you and your family.", "愿主赐福给你和你的家人。", String(repeating: "完整译文🌿。Complete translation. ", count: 40)] {
            let pages = SubtitleTextLayout.pages(text: text, font: font, width: 420, height: 130)
            assert(!pages.isEmpty && pages.allSatisfy { !$0.isEmpty })
            assert(pages.joined() == text, "pagination must preserve every character and emoji")
            assert(pages.count <= text.count)
        }
        assert(SubtitleTextLayout.pages(text: "", font: font, width: 420, height: 130).isEmpty)
        assert(SubtitleTextLayout.pages(text: String(repeating: "字幕", count: 100), font: .systemFont(ofSize: 100), width: 300, height: 240).count > 1)
        for size in [CGSize(width: 640, height: 480), CGSize(width: 1470, height: 880)] {
            for pointSize in [12.0, 36, 144] {
                var style = SubtitlePreferences(); style.fontSize = pointSize; style.widthFraction = 0.25
                style.shadowBlur = 30; style.shadowOffset = 20
                let text = String(repeating: "完整译文。Complete translation. ", count: 10)
                let layout = SubtitleTextLayout.layout(text: text, preferences: style, screen: CGRect(origin: .zero, size: size))!
                assert(layout.pages.joined() == text)
                let inset = SubtitleTextLayout.padding(layout.preferences)
                for page in layout.pages {
                    let attributes = SubtitleTextLayout.attributed(page, font: SubtitleTextLayout.font(layout.preferences))
                    let setter = CTFramesetterCreateWithAttributedString(attributes)
                    let path = CGPath(rect: CGRect(origin: .zero, size: CGSize(width: layout.frame.width - 2 * inset, height: layout.frame.height - 2 * inset)), transform: nil)
                    let visible = CTFrameGetVisibleStringRange(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil))
                    assert(visible.length == (page as NSString).length, "Every paginated character must actually fit the drawn frame")
                }
            }
        }
        var settings = SubtitlePreferences()
        settings.fontSize = 42; settings.textColorHex = "#FFE680"
        settings.shadowOpacity = 0.85; settings.shadowBlur = 6; settings.shadowOffset = 3
        let view = SubtitleTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 180))
        view.apply(text: "愿平安与你们同在。\nMay peace be with you.", preferences: settings)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("no render bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/voxbridge-subtitle-render.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        // A straight-edged backdrop uses the shared color/opacity independently
        // of text shadow, and never appears without caption text.
        settings.shadowEnabled = false; settings.backgroundEnabled = true
        settings.shadowColorHex = "#204060"; settings.shadowOpacity = 0.8
        let backgroundView = SubtitleTextView(frame: view.bounds)
        func sample(_ text: String) -> NSColor {
            let rendered = backgroundView.bitmapImageRepForCachingDisplay(in: backgroundView.bounds)!
            backgroundView.cacheDisplay(in: backgroundView.bounds, to: rendered)
            let setter = CTFramesetterCreateWithAttributedString(SubtitleTextLayout.attributed(text, font: SubtitleTextLayout.font(settings)))
            let path = CGPath(rect: backgroundView.bounds.insetBy(dx: 8, dy: 8), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            let box = SubtitleTextLayout.backgroundRects(for: frame, fontSize: settings.fontSize, in: backgroundView.bounds)[0]
            let scale = CGFloat(rendered.pixelsWide) / backgroundView.bounds.width
            return rendered.colorAt(x: Int((box.minX + 1) * scale), y: Int((backgroundView.bounds.maxY - box.maxY + 1) * scale))!.usingColorSpace(.sRGB)!
        }
        backgroundView.apply(text: "矩形背景 Rectangle", preferences: settings)
        let filled = sample("矩形背景 Rectangle")
        assert(abs(filled.alphaComponent - 0.8) < 0.02)
        assert(abs(filled.redComponent - 32.0 / 255) < 0.02 && abs(filled.blueComponent - 96.0 / 255) < 0.02)
        backgroundView.setBackgroundEnabled(false)
        assert(sample("矩形背景 Rectangle").alphaComponent == 0, "disabling background restores transparency")
        backgroundView.apply(text: "", preferences: settings)
        assert(sample("矩形背景 Rectangle").alphaComponent == 0, "no empty background rectangle between captions")
        let panel = SubtitleOverlayPanel()
        assert(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
        assert(!panel.isOpaque && !panel.hidesOnDeactivate)
        assert(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.close()
        let overlay = SubtitleOverlayController()
        var large = SubtitlePreferences(); large.fontSize = 144; large.widthFraction = 0.25; large.shadowEnabled = false
        overlay.apply(preferences: large)
        let long = String(repeating: "第一段完整译文。第二段重复语句。第三段中文测试。第四段完成显示。", count: 8)
        let expected = SubtitleTextLayout.layout(text: long, preferences: large, screen: NSScreen.screens[0].frame)!.pages
        assert(expected.count > 2 && expected[0] != expected[1])
        func waitForPage(_ index: Int, after previous: Int) async throws {
            // Wait for the real page transition; a fixed sleep plus 150 ms can
            // race AppKit's main-actor scheduling on a busy desktop.
            let deadline = ContinuousClock.now.advanced(by: .seconds(SubtitleTextLayout.readingSeconds(expected[previous]) + 1))
            while overlay.textView.accessibilityValue() as? String != expected[index], ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        overlay.setLiveText(long, identity: .init(sentenceID: "one", revision: 1), active: true)
        overlay.panel.orderOut(nil)
        assert(overlay.textView.accessibilityValue() as? String == expected[0])
        try await waitForPage(1, after: 0)
        assert(overlay.textView.accessibilityValue() as? String == expected[1])
        let beforeBackground = overlay.panel.frame
        overlay.apply(preferences: overlay.adjustedPreferences(for: .background))
        assert(overlay.panel.frame == beforeBackground)
        assert(overlay.textView.accessibilityValue() as? String == expected[1], "background toggle must preserve the current page")
        overlay.apply(preferences: overlay.adjustedPreferences(for: .up))
        assert(overlay.textView.accessibilityValue() as? String == expected[1], "moving must not reset a long caption to page one")
        overlay.apply(preferences: overlay.adjustedPreferences(for: .toggle))
        assert(!overlay.panel.isVisible)
        try await waitForPage(2, after: 1)
        overlay.apply(preferences: overlay.adjustedPreferences(for: .toggle))
        assert(overlay.textView.accessibilityValue() as? String == expected[2], "hidden captions must retain their page clock and resume the current page")
        let nextPageBitmap = overlay.textView.bitmapImageRepForCachingDisplay(in: overlay.textView.bounds)!
        overlay.textView.cacheDisplay(in: overlay.textView.bounds, to: nextPageBitmap)
        let pageSetter = CTFramesetterCreateWithAttributedString(SubtitleTextLayout.attributed(expected[2], font: SubtitleTextLayout.font(large)))
        let pagePath = CGPath(rect: overlay.textView.bounds.insetBy(dx: 8, dy: 8), transform: nil)
        let pageFrame = CTFramesetterCreateFrame(pageSetter, CFRange(location: 0, length: 0), pagePath, nil)
        let pageBox = SubtitleTextLayout.backgroundRects(for: pageFrame, fontSize: large.fontSize, in: overlay.textView.bounds)[0]
        let pageScale = CGFloat(nextPageBitmap.pixelsWide) / overlay.textView.bounds.width
        let nextPageFill = nextPageBitmap.colorAt(x: Int((pageBox.minX + 1) * pageScale),
            y: Int((overlay.textView.bounds.maxY - pageBox.maxY + 1) * pageScale))!
        assert(nextPageFill.alphaComponent > 0.8, "later pages must retain the toggled background")
        overlay.setLiveText(long, identity: .init(sentenceID: "two", revision: 1), active: true)
        overlay.panel.orderOut(nil)
        assert(overlay.textView.accessibilityValue() as? String == expected[0], "a repeated sentence must restart on page one")
        overlay.setLiveText("", identity: nil, active: false)
        assert(!overlay.panel.isVisible && overlay.textView.accessibilityValue() as? String == "")
        overlay.setLiveText(long, identity: .init(sentenceID: "spoken", revision: 1), synchronized: true, active: true)
        overlay.panel.orderOut(nil)
        assert(overlay.textView.accessibilityValue() as? String == long, "the entire audible chunk must be visible without timed pagination")
        try await Task.sleep(nanoseconds: 3_100_000_000)
        assert(overlay.textView.accessibilityValue() as? String == long, "a slow or paused TTS must not lose its caption to a wall-clock timer")
        let fitted = SubtitleTextLayout.layout(text: long, preferences: large, screen: NSScreen.screens[0].frame, fitCompleteText: true)!
        assert(fitted.pages == [long])
        let inset = SubtitleTextLayout.padding(fitted.preferences)
        let setter = CTFramesetterCreateWithAttributedString(SubtitleTextLayout.attributed(long, font: SubtitleTextLayout.font(fitted.preferences)))
        let fittedPath = CGPath(rect: CGRect(origin: .zero, size: CGSize(width: fitted.frame.width - 2 * inset, height: fitted.frame.height - 2 * inset)), transform: nil)
        assert(CTFrameGetVisibleStringRange(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), fittedPath, nil)).length == (long as NSString).length)
        large.verticalPosition = 1
        overlay.apply(preferences: large); overlay.panel.orderOut(nil)
        assert(overlay.panel.frame.minY == NSScreen.screens[0].frame.minY, "actual panel must cover Dock and reach screen bottom")
        overlay.close()
        print("PASS: lossless completed-caption pagination, Unicode render, nonactivating click-through panel")
    }
}
