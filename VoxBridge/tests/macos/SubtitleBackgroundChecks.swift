import AppKit

@MainActor func rendered(_ view: NSView) -> NSBitmapImageRep {
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

func visibleLineBands(_ bitmap: NSBitmapImageRep) -> [CGRect] {
    assert(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4 && bitmap.hasAlpha)
    let data = bitmap.bitmapData!
    let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    var result: [CGRect] = [], band = CGRect.null
    for y in 0..<bitmap.pixelsHigh {
        var first: Int?, last = 0
        for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + alpha] > 8 {
            if first == nil { first = x }; last = x
        }
        if let first { band = band.union(CGRect(x: first, y: y, width: last - first + 1, height: 1)) }
        else if !band.isNull { result.append(band); band = .null }
    }
    if !band.isNull { result.append(band) }
    return result
}

func visiblePixels(_ bitmap: NSBitmapImageRep) -> CGRect {
    visibleLineBands(bitmap).reduce(.null) { $0.union($1) }
}

@main struct SubtitleBackgroundChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var style = SubtitlePreferences()
        style.fontSize = 36; style.shadowEnabled = false
        style.textColorHex = "#FFFFFF"; style.shadowColorHex = "#204060"; style.shadowOpacity = 0.8
        let view = SubtitleTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 220))
        let samples = ["Hi", "这是短句。", "A longer English sentence with punctuation.",
                       "较长的第一行字幕\n短句", "日本語の字幕", "Français : Écoutez bien !",
                       "Español: ¡Buenos días!", "Italiano: Buongiorno", "Português: Bom dia!",
                       "नमस्ते दुनिया", "🌍🎉", "Hello 🌍 नमस्ते"]
        var rectangles: [CGRect] = []
        for text in samples {
            style.backgroundEnabled = false
            view.apply(text: text, preferences: style)
            let glyphs = rendered(view), ink = visiblePixels(glyphs)
            assert(!ink.isNull, "sample must render: \(text)")
            style.backgroundEnabled = true
            view.apply(text: text, preferences: style)
            let backed = rendered(view), box = visiblePixels(backed)
            let scale = CGFloat(backed.pixelsWide) / view.bounds.width
            assert(box.contains(ink), "background must surround every visible glyph: \(text)")
            assert(box.width - ink.width <= 20 * scale && box.height - ink.height <= 13 * scale,
                   "rectangle must tightly follow visible text, not the window: \(text) \(ink) \(box)")
            assert(box.width > ink.width && box.height > ink.height)
            assert(backed.colorAt(x: 2, y: 2)!.alphaComponent == 0, "unused window area must stay transparent")
            let bands = visibleLineBands(backed)
            let first = bands[0]
            let fill = backed.colorAt(x: Int(first.minX + 1), y: Int(first.minY + 1))!.usingColorSpace(.sRGB)!
            assert(abs(fill.alphaComponent - 0.8) < 0.02)
            assert(abs(fill.redComponent - 32.0 / 255) < 0.02 && abs(fill.blueComponent - 96.0 / 255) < 0.02)
            rectangles.append(box)
            if text.contains("\n") {
                assert(bands.count == 2, "each line needs a separate rectangle with a transparent gap")
                assert(bands[0].width > bands[1].width * 2, "each rectangle must fit its own line")
                assert(bands[0].maxY < bands[1].minY)
                assert(backed.colorAt(x: Int(bands[0].minX + 2), y: Int(bands[1].midY))!.alphaComponent == 0,
                       "a short line must not inherit the longer line's background width")
            }
            if let output = CommandLine.arguments.dropFirst().first, text == "较长的第一行字幕\n短句" {
                try backed.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
            }
        }
        assert(rectangles[0].width < rectangles[1].width && rectangles[1].width < rectangles[2].width)
        assert(rectangles[3].height > rectangles[0].height * 1.5, "multiline captions grow vertically")
        // Updating text in the same view must remove the previous, wider rectangle.
        view.apply(text: "Hi", preferences: style)
        assert(visiblePixels(rendered(view)) == rectangles[0])
        view.setBackgroundEnabled(false)
        assert(visiblePixels(rendered(view)).width < rectangles[0].width)
        for empty in ["", "  \n  "] {
            view.apply(text: empty, preferences: style)
            assert(visiblePixels(rendered(view)).isNull, "empty captions must not leave a rectangle")
        }
        view.frame.size.width = 320
        view.frame.size.height = 400
        view.apply(text: "Automatic wrapping also needs a separate background behind each line.", preferences: style)
        let wrapped = visibleLineBands(rendered(view))
        assert(wrapped.count > 2, "automatic wraps must create independent boxes")
        assert(wrapped.map(\.width).min()! < wrapped.map(\.width).max()! - 10)
        for size in [12.0, 36, 72] {
            style.fontSize = size
            view.frame.size.width = 800
            view.apply(text: "长一些的字幕\n短句", preferences: style)
            assert(visibleLineBands(rendered(view)).count == 2, "line boxes must stay separate at font size \(size)")
            view.apply(text: "长一些的字幕\n\n短句", preferences: style)
            assert(visibleLineBands(rendered(view)).count == 2, "empty lines must not produce boxes")
        }
        print("PASS: per-line backgrounds, automatic wrapping, blank lines, eight languages, shared color and clean redraw")
    }
}
