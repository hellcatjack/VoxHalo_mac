import AppKit

public struct SubtitleLayoutSettings: Equatable, Sendable {
    public var targetAreaHeight: CGFloat
    public var targetFontSize: CGFloat
    public var targetTopOffset: CGFloat
    public var targetColor: String
    public var referenceAreaHeight: CGFloat
    public var referenceFontSize: CGFloat
    public var referenceBottomOffset: CGFloat
    public var referenceColor: String

    public init(
        targetAreaHeight: CGFloat,
        targetFontSize: CGFloat,
        targetTopOffset: CGFloat,
        targetColor: String,
        referenceAreaHeight: CGFloat,
        referenceFontSize: CGFloat,
        referenceBottomOffset: CGFloat,
        referenceColor: String
    ) {
        self.targetAreaHeight = targetAreaHeight
        self.targetFontSize = targetFontSize
        self.targetTopOffset = targetTopOffset
        self.targetColor = targetColor
        self.referenceAreaHeight = referenceAreaHeight
        self.referenceFontSize = referenceFontSize
        self.referenceBottomOffset = referenceBottomOffset
        self.referenceColor = referenceColor
    }

    public init(settings: AppSettings) {
        self.init(
            targetAreaHeight: settings.targetAreaHeight,
            targetFontSize: settings.targetFontSize,
            targetTopOffset: settings.targetTopOffset,
            targetColor: settings.targetColor,
            referenceAreaHeight: settings.referenceAreaHeight,
            referenceFontSize: settings.referenceFontSize,
            referenceBottomOffset: settings.referenceBottomOffset,
            referenceColor: settings.referenceColor
        )
    }

    public static let defaults = SubtitleLayoutSettings(
        targetAreaHeight: 264,
        targetFontSize: 36,
        targetTopOffset: 0,
        targetColor: "#FFFFFF",
        referenceAreaHeight: 96,
        referenceFontSize: 24,
        referenceBottomOffset: 0,
        referenceColor: "#F4F4F4"
    )

    func normalized() -> SubtitleLayoutSettings {
        SubtitleLayoutSettings(
            targetAreaHeight: Self.positive(
                targetAreaHeight,
                default: 264,
                range: 120 ... 640
            ),
            targetFontSize: Self.positive(
                targetFontSize,
                default: 36,
                range: 18 ... 56
            ),
            targetTopOffset: Self.offset(targetTopOffset),
            targetColor: Self.color(targetColor, default: "#FFFFFF"),
            referenceAreaHeight: Self.positive(
                referenceAreaHeight,
                default: 96,
                range: 48 ... 360
            ),
            referenceFontSize: Self.positive(
                referenceFontSize,
                default: 24,
                range: 16 ... 42
            ),
            referenceBottomOffset: Self.offset(referenceBottomOffset),
            referenceColor: Self.color(referenceColor, default: "#F4F4F4")
        )
    }

    private static func positive(
        _ value: CGFloat,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func offset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 900)
    }

    private static func color(_ value: String, default defaultValue: String) -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        guard normalized.count == 7,
              normalized.first == "#",
              normalized.dropFirst().allSatisfy(\.isHexDigit) else {
            return defaultValue
        }
        return normalized
    }
}

@MainActor
public final class SubtitleOverlayView: NSView {
    private static let edgeInset: CGFloat = 64
    private static let regionGap: CGFloat = 14

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

    public override init(frame frameRect: NSRect) {
        targetTextView = OutlinedTextView(frame: .zero)
        referenceTextView = OutlinedTextView(frame: .zero)
        targetRegion = Self.makeRegion(documentView: targetTextView)
        referenceRegion = Self.makeRegion(documentView: referenceTextView)
        super.init(frame: frameRect)

        wantsLayer = false
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
            targetTextView.text = target
            queueTargetScroll()
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
        targetTextView.textFont = .systemFont(
            ofSize: layoutSettings.targetFontSize,
            weight: .semibold
        )
        targetTextView.textColor = NSColor(
            voxHaloHex: layoutSettings.targetColor,
            fallback: .white
        )
        targetTextView.outlineWidth = 1.8

        referenceTextView.alignment = .left
        referenceTextView.textFont = .systemFont(
            ofSize: layoutSettings.referenceFontSize,
            weight: .semibold
        )
        referenceTextView.textColor = NSColor(
            voxHaloHex: layoutSettings.referenceColor,
            fallback: NSColor(white: 0.96, alpha: 1)
        )
        referenceTextView.outlineWidth = 1.6
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
        let height = max(viewport.height, textView.heightThatFits(width: width))
        textView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        textView.prepareLayoutCache()
    }

    private func queueTargetScroll() {
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
        layoutDocument(targetTextView, in: targetRegion)
        scrollToBottom(targetRegion)
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
