import AppKit

@MainActor
public final class SubtitleOverlayView: NSView {
    private static let edgeInset: CGFloat = 64
    private static let regionGap: CGFloat = 14
    private static let bottomFollowTolerance: CGFloat = 2

    public let targetRegion: NSScrollView
    public let referenceRegion: NSScrollView
    public let targetTextView: OutlinedTextView
    public let referenceTextView: OutlinedTextView

    public private(set) var layoutSettings = SubtitleLayoutSettings.defaults
    public private(set) var display: DisplayDescriptor?
    private(set) var targetScrollScheduleCount = 0
    private(set) var referenceScrollScheduleCount = 0
    private(set) var isTargetScrollPending = false
    private(set) var isReferenceScrollPending = false
    private var targetScrollFollowsBottom = false

    public override init(frame frameRect: NSRect) {
        targetTextView = OutlinedTextView(frame: .zero)
        referenceTextView = OutlinedTextView(frame: .zero)
        targetRegion = Self.makeRegion(documentView: targetTextView)
        referenceRegion = Self.makeRegion(documentView: referenceTextView)
        super.init(frame: frameRect)

        wantsLayer = false
        targetTextView.setAccessibilityIdentifier("overlay.translation")
        targetTextView.setAccessibilityLabel("Translation subtitles")
        referenceTextView.setAccessibilityIdentifier("overlay.recognition")
        referenceTextView.setAccessibilityLabel("Recognition subtitles")
        addSubview(targetRegion)
        addSubview(referenceRegion)
        applyTextStyle()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public func apply(
        layout: SubtitleLayoutSettings,
        display: DisplayDescriptor
    ) {
        self.display = display
        apply(layout: layout)
    }

    public func apply(layout: SubtitleLayoutSettings) {
        let normalized = layout.normalized()
        guard normalized != layoutSettings else { return }
        layoutSettings = normalized
        applyTextStyle()
        needsLayout = true
        queueTargetScroll()
        queueReferenceScroll()
    }

    public func apply(model: SubtitleDisplayModel) {
        let target = model.primaryText
        let reference = SubtitleText.joined(model.referenceSegments)
        if targetTextView.text != target {
            // Capture the reader's intent before changing the text or its
            // document height. A structural correction must keep following
            // the newest edge when the reader was already there; otherwise a
            // single extra wrapped line permanently strands the viewport above
            // every later translation. A reader who actually scrolled up still
            // keeps the same position across both corrections and appends.
            let followsBottom = shouldFollowTargetBottom()
            targetTextView.text = target
            queueTargetScroll(followsBottom: followsBottom)
        }
        if referenceTextView.text != reference {
            referenceTextView.text = reference
            queueReferenceScroll()
        }
    }

    public override func layout() {
        super.layout()
        let oldTargetFrame = targetRegion.frame
        let oldReferenceFrame = referenceRegion.frame
        let horizontalInset = min(Self.edgeInset, max(0, bounds.width / 2))
        let verticalInset = min(Self.edgeInset, max(0, bounds.height / 2))
        let content = bounds.insetBy(
            dx: horizontalInset,
            dy: verticalInset
        )
        let availableHeight = max(0, content.height)
        let referenceHeight = min(
            layoutSettings.referenceAreaHeight,
            max(0, availableHeight - Self.regionGap)
        )
        let targetHeight = min(
            layoutSettings.targetAreaHeight,
            max(0, availableHeight - Self.regionGap - referenceHeight)
        )
        let freeSpace = max(
            0,
            availableHeight - targetHeight - referenceHeight - Self.regionGap
        )
        let referenceOffset = min(
            layoutSettings.referenceBottomOffset,
            freeSpace
        )
        let targetOffset = min(
            layoutSettings.targetTopOffset,
            max(0, freeSpace - referenceOffset)
        )

        referenceRegion.frame = CGRect(
            x: content.minX,
            y: content.minY + referenceOffset,
            width: content.width,
            height: referenceHeight
        )
        targetRegion.frame = CGRect(
            x: content.minX,
            y: content.maxY - targetOffset - targetHeight,
            width: content.width,
            height: targetHeight
        )

        layoutDocument(targetTextView, in: targetRegion)
        layoutDocument(referenceTextView, in: referenceRegion)
        if targetRegion.frame != oldTargetFrame {
            queueTargetScroll()
        }
        if referenceRegion.frame != oldReferenceFrame {
            queueReferenceScroll()
        }
    }

    func flushPendingScrolls() {
        performTargetScroll()
        performReferenceScroll()
    }

    private func applyTextStyle() {
        targetTextView.alignment = .left
        targetTextView.textFont = Self.font(
            named: "PingFangSC-Semibold",
            size: layoutSettings.targetFontSize,
            fallbackWeight: .semibold
        )
        targetTextView.textColor = NSColor(
            voxHaloHex: layoutSettings.targetColor,
            fallback: .white
        )
        targetTextView.outlineWidth = 1.0

        referenceTextView.alignment = .left
        referenceTextView.textFont = Self.font(
            named: "PingFangSC-Medium",
            size: layoutSettings.referenceFontSize,
            fallbackWeight: .medium
        )
        referenceTextView.textColor = NSColor(
            voxHaloHex: layoutSettings.referenceColor,
            fallback: NSColor(white: 0.96, alpha: 1)
        )
        referenceTextView.outlineWidth = 0.85
    }

    private static func font(
        named postScriptName: String,
        size: CGFloat,
        fallbackWeight: NSFont.Weight
    ) -> NSFont {
        NSFont(name: postScriptName, size: size)
            ?? .systemFont(ofSize: size, weight: fallbackWeight)
    }

    private static func makeRegion(
        documentView: OutlinedTextView
    ) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.scrollerStyle = .overlay
        scroll.documentView = documentView
        return scroll
    }

    private func layoutDocument(
        _ textView: OutlinedTextView,
        in scrollView: NSScrollView
    ) {
        let viewport = scrollView.contentView.bounds.size
        let width = max(1, viewport.width)
        let contentHeight = textView.heightThatFits(width: width)
        let overflow = max(0, contentHeight - viewport.height)
        let lineHeight = max(1, textView.layoutLineHeight)
        let alignedOverflow = overflow > 0
            ? ceil(overflow / lineHeight) * lineHeight
            : 0
        let height = max(
            viewport.height,
            viewport.height + alignedOverflow
        )
        textView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        textView.prepareLayoutCache()
    }

    private func queueTargetScroll(followsBottom: Bool = true) {
        targetScrollFollowsBottom = targetScrollFollowsBottom || followsBottom
        guard !isTargetScrollPending else { return }
        isTargetScrollPending = true
        targetScrollScheduleCount += 1
        DispatchQueue.main.async { [weak self] in
            self?.performTargetScroll()
        }
    }

    private func queueReferenceScroll() {
        guard !isReferenceScrollPending else { return }
        isReferenceScrollPending = true
        referenceScrollScheduleCount += 1
        DispatchQueue.main.async { [weak self] in
            self?.performReferenceScroll()
        }
    }

    private func performTargetScroll() {
        guard isTargetScrollPending else { return }
        isTargetScrollPending = false
        let followsBottom = targetScrollFollowsBottom
        targetScrollFollowsBottom = false
        let previousOrigin = targetRegion.contentView.bounds.origin
        layoutDocument(targetTextView, in: targetRegion)
        if followsBottom {
            scrollToBottom(targetRegion)
        } else {
            restoreScrollPosition(previousOrigin, in: targetRegion)
        }
    }

    private func performReferenceScroll() {
        guard isReferenceScrollPending else { return }
        isReferenceScrollPending = false
        layoutDocument(referenceTextView, in: referenceRegion)
        scrollToBottom(referenceRegion)
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let y = max(
            0,
            documentView.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restoreScrollPosition(
        _ origin: NSPoint,
        in scrollView: NSScrollView
    ) {
        guard let documentView = scrollView.documentView else { return }
        let maximumY = max(
            0,
            documentView.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: min(max(0, origin.y), maximumY)
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func shouldFollowTargetBottom() -> Bool {
        if targetTextView.text.isEmpty { return true }
        if isTargetScrollPending, targetScrollFollowsBottom { return true }
        guard let documentView = targetRegion.documentView else { return true }
        let maximumY = max(
            0,
            documentView.frame.height - targetRegion.contentView.bounds.height
        )
        return maximumY - targetRegion.contentView.bounds.origin.y
            <= Self.bottomFollowTolerance
    }

}

private extension NSColor {
    convenience init(voxHaloHex value: String, fallback: NSColor) {
        let text = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        guard text.count == 7,
              text.first == "#",
              let red = UInt8(text.dropFirst().prefix(2), radix: 16),
              let green = UInt8(text.dropFirst(3).prefix(2), radix: 16),
              let blue = UInt8(text.dropFirst(5).prefix(2), radix: 16) else {
            let rgb = fallback.usingColorSpace(.sRGB) ?? .white
            self.init(
                srgbRed: rgb.redComponent,
                green: rgb.greenComponent,
                blue: rgb.blueComponent,
                alpha: rgb.alphaComponent
            )
            return
        }
        self.init(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}
