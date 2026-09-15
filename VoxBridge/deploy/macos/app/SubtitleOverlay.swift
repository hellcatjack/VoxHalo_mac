import AppKit
import CoreText

extension NSColor {
    convenience init(subtitleHex: String) {
        let value = UInt32(subtitleHex.dropFirst(), radix: 16) ?? 0xFFFFFF
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var subtitleHex: String {
        let rgb = usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

@MainActor enum SubtitleTextLayout {
    static func font(_ preferences: SubtitlePreferences) -> NSFont {
        NSFont(name: preferences.fontName, size: preferences.fontSize)
            ?? .systemFont(ofSize: preferences.fontSize, weight: .semibold)
    }
    static func attributed(_ text: String, font: NSFont, color: NSColor = .white) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = font.pointSize * 0.12
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    static func height(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, font: font))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: max(1, width), height: 100_000), nil)
        return ceil(max(size.height + 4, font.ascender - font.descender + font.leading + 4))
    }
    static func pages(text: String, font: NSFont, width: CGFloat, height: CGFloat) -> [String] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, font: font))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)), transform: nil)
        var start = 0, result: [String] = []
        while start < source.length {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            var end = min(source.length, start + visible.length)
            // Keep surrogate pairs and extended graphemes intact at a page boundary.
            if end > start && end < source.length {
                let boundary = source.rangeOfComposedCharacterSequence(at: end)
                if boundary.location < end { end = boundary.location }
            }
            if end <= start { end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: start)) }
            result.append(source.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        return result
    }
    struct Layout {
        let preferences: SubtitlePreferences
        let frame: CGRect
        let pages: [String]
    }
    static func padding(_ p: SubtitlePreferences) -> CGFloat {
        p.shadowEnabled ? ceil(p.shadowBlur * 2 + p.shadowOffset + 6) : 8
    }
    static func layout(text: String, preferences: SubtitlePreferences, screen: CGRect, fitCompleteText: Bool = false) -> Layout? {
        var style = preferences.normalized()
        let safe = SubtitlePreferences.frame(in: screen, size: screen.size, horizontal: 0, vertical: 0)
        let inset = padding(style)
        guard safe.width > 2 * inset + 24, safe.height > 2 * inset + 24 else { return nil }
        // Preserve the chosen size whenever possible, while fitting a complete line
        // even with a large shadow or after moving to a smaller monitor.
        style.fontSize = min(style.fontSize, max(12, min((safe.height - 2 * inset) / 2, (safe.width - 2 * inset) / 2)))
        var font = font(style)
        var width = min(safe.width, max(2 * inset + font.pointSize * 2, safe.width * style.widthFraction))
        var textWidth = width - 2 * inset
        let lineHeight = font.ascender - font.descender + font.leading + 4
        let availableHeight = safe.height - 2 * inset
        var textHeight = min(availableHeight, max(lineHeight, min(safe.height * 0.35, height(text: text, font: font, width: textWidth))))
        if fitCompleteText {
            func fittingSize(width: CGFloat, height limit: CGFloat) -> CGFloat {
                var lower: CGFloat = 1, upper = style.fontSize
                for _ in 0..<14 {
                    let middle = (lower + upper) / 2
                    var candidate = style; candidate.fontSize = middle
                    if height(text: text, font: Self.font(candidate), width: width) <= limit { lower = middle }
                    else { upper = middle }
                }
                return lower
            }
            let limit = min(availableHeight, max(lineHeight, safe.height * 0.35))
            if height(text: text, font: font, width: textWidth) > limit {
                var size = fittingSize(width: textWidth, height: limit)
                if size < 12 {
                    width = safe.width; textWidth = width - 2 * inset
                    size = fittingSize(width: textWidth, height: availableHeight)
                }
                style.fontSize = size; font = Self.font(style)
            }
            textHeight = min(availableHeight, height(text: text, font: font, width: textWidth))
        }
        let frame = SubtitlePreferences.frame(in: screen, size: CGSize(width: width, height: textHeight + 2 * inset),
                                              horizontal: style.horizontalPosition, vertical: style.verticalPosition)
        let pages = fitCompleteText ? [text] : pages(text: text, font: font, width: frame.width - 2 * inset, height: frame.height - 2 * inset)
        return Layout(preferences: style, frame: frame, pages: pages)
    }
    static func readingSeconds(_ text: String) -> Double {
        let chinese = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return min(12, max(3, Double(max(chinese, words * 2)) / 5 + 1))
    }
}

@MainActor final class SubtitleTextView: NSView {
    private var text = ""
    private var preferences = SubtitlePreferences()
    var padding: CGFloat {
        SubtitleTextLayout.padding(preferences)
    }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func apply(text: String, preferences: SubtitlePreferences) {
        var normalized = preferences.normalized()
        // Layout may reduce the rendered size to keep a whole spoken unit on
        // screen. The user's saved font-size preference remains untouched.
        if preferences.fontSize.isFinite { normalized.fontSize = min(normalized.fontSize, max(1, preferences.fontSize)) }
        guard self.text != text || self.preferences != normalized else { return }
        self.text = text; self.preferences = normalized
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(NativeLocalization.text("翻译字幕")); setAccessibilityValue(text)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes = SubtitleTextLayout.attributed(text, font: SubtitleTextLayout.font(preferences),
                                                      color: NSColor(subtitleHex: preferences.textColorHex))
        let setter = CTFramesetterCreateWithAttributedString(attributes)
        let path = CGPath(rect: bounds.insetBy(dx: padding, dy: padding), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState(); context.textMatrix = .identity
        if preferences.shadowEnabled {
            context.setShadow(offset: CGSize(width: preferences.shadowOffset, height: -preferences.shadowOffset),
                              blur: preferences.shadowBlur,
                              color: NSColor(subtitleHex: preferences.shadowColorHex).withAlphaComponent(preferences.shadowOpacity).cgColor)
        }
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

@MainActor final class SubtitleOverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = NativeLocalization.text("翻译字幕"); isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true; level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor enum SubtitleDisplays {
    static func id(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    static func selected(_ id: String) -> NSScreen? {
        NSScreen.screens.first(where: { !id.isEmpty && Self.id($0) == id }) ?? NSScreen.screens.first
    }
}

@MainActor final class SubtitleOverlayController {
    let panel = SubtitleOverlayPanel()
    let textView = SubtitleTextView(frame: .zero)
    private var preferences = SubtitlePreferences()
    private var liveText = ""
    private var identity: CompletedSubtitleState.Identity?
    private var synchronized = false
    private var active = false
    private var preview = false
    private var observer: NSObjectProtocol?
    private var pageTask: Task<Void, Never>?
    private var generation = UUID()
    private struct LayoutKey: Equatable { let text: String; let identity: CompletedSubtitleState.Identity?; let synchronized: Bool; let preferences: SubtitlePreferences; let screen: CGRect }
    private var lastLayout: LayoutKey?

    init() {
        panel.contentView = textView; textView.autoresizingMask = [.width, .height]
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; pageTask?.cancel() }
    func apply(preferences: SubtitlePreferences) {
        self.preferences = preferences.normalized(); render()
    }
    func setLiveText(_ text: String, identity: CompletedSubtitleState.Identity?, synchronized: Bool = false, active: Bool) {
        guard text != liveText || identity != self.identity || synchronized != self.synchronized || active != self.active else { return }
        liveText = text; self.identity = identity; self.synchronized = synchronized; self.active = active
        if active { preview = false }
        render()
    }
    func refreshLocalization() {
        panel.title = NativeLocalization.text("翻译字幕")
        textView.setAccessibilityLabel(NativeLocalization.text("翻译字幕"))
        if preview { render() }
    }
    func setPreview(_ enabled: Bool) { preview = enabled && !active; render() }
    func close() { active = false; liveText = ""; preview = false; hide() }
    private func hide() {
        generation = UUID(); pageTask?.cancel(); pageTask = nil; lastLayout = nil
        textView.apply(text: "", preferences: preferences)
        if panel.isVisible { panel.orderOut(nil) }
    }
    private func render() {
        let text = preview ? NativeLocalization.text("字幕样式预览") + "\n" + NativeLocalization.text("这是翻译字幕的显示效果。") : (active ? liveText : "")
        guard (preferences.enabled || preview), !text.isEmpty, let screen = SubtitleDisplays.selected(preferences.screenID) else { hide(); return }
        let key = LayoutKey(text: text, identity: identity, synchronized: synchronized, preferences: preferences, screen: screen.frame)
        guard lastLayout != key else { return }
        lastLayout = key
        generation = UUID(); let run = generation
        pageTask?.cancel(); pageTask = nil
        guard let layout = SubtitleTextLayout.layout(text: text, preferences: preferences, screen: screen.frame, fitCompleteText: synchronized && !preview) else { hide(); return }
        let style = layout.preferences, frame = layout.frame, pages = layout.pages
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        textView.frame = CGRect(origin: .zero, size: frame.size)
        textView.apply(text: pages.first ?? "", preferences: style)
        if !panel.isVisible { panel.orderFrontRegardless() }
        if pages.count > 1 && (!synchronized || preview) {
            pageTask = Task { [weak self] in
                for index in 1..<pages.count {
                    do { try await Task.sleep(nanoseconds: UInt64(SubtitleTextLayout.readingSeconds(pages[index - 1]) * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.generation == run else { return }
                    self.textView.apply(text: pages[index], preferences: style)
                }
            }
        }
    }
}
