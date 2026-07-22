import AppKit
import CoreText

@MainActor
public final class OutlinedTextView: NSView {
    private struct ColorComponents: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private struct FramesetterKey: Equatable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let textColor: ColorComponents
        let outlineColor: ColorComponents
        let outlineWidth: CGFloat
        let alignment: NSTextAlignment
        let width: CGFloat
    }

    private var storedText = ""
    private var storedFont = NSFont.systemFont(ofSize: 36, weight: .semibold)
    private var storedTextColor = NSColor.white
    private var storedOutlineColor = NSColor.black.withAlphaComponent(0.9)
    private var storedOutlineWidth: CGFloat = 1.8
    private var storedAlignment = NSTextAlignment.left
    private var cachedKey: FramesetterKey?
    private var cachedFramesetter: CTFramesetter?
    private var cachedOutlineFramesetter: CTFramesetter?
    private var cachedPath: CGPath?
    private var cachedPathSize: CGSize?
    private var identitySequence: UInt64 = 0

    public private(set) var contentGeneration: UInt64 = 0
    public private(set) var cacheBuildCount = 0
    public private(set) var cachedFramesetterIdentity: UInt64?
    public private(set) var cachedPathIdentity: UInt64?
    var cachedAttributedText: NSAttributedString?
    var cachedOutlineAttributedText: NSAttributedString?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override var mouseDownCanMoveWindow: Bool { false }

    public var text: String {
        get { storedText }
        set {
            let normalized = SubtitleText.normalized(newValue)
            guard normalized != storedText else { return }
            storedText = normalized
            contentGeneration &+= 1
            invalidateTextLayout()
        }
    }

    public var textFont: NSFont {
        get { storedFont }
        set {
            guard !storedFont.isEqual(newValue) else { return }
            storedFont = newValue
            invalidateTextLayout()
        }
    }

    public var textColor: NSColor {
        get { storedTextColor }
        set {
            guard !storedTextColor.isEqual(newValue) else { return }
            storedTextColor = newValue
            invalidateTextLayout()
        }
    }

    public var outlineColor: NSColor {
        get { storedOutlineColor }
        set {
            guard !storedOutlineColor.isEqual(newValue) else { return }
            storedOutlineColor = newValue
            invalidateTextLayout()
        }
    }

    public var outlineWidth: CGFloat {
        get { storedOutlineWidth }
        set {
            let normalized = max(0, newValue.isFinite ? newValue : 0)
            guard normalized != storedOutlineWidth else { return }
            storedOutlineWidth = normalized
            invalidateTextLayout()
        }
    }

    public var alignment: NSTextAlignment {
        get { storedAlignment }
        set {
            guard newValue != storedAlignment else { return }
            storedAlignment = newValue
            invalidateTextLayout()
        }
    }

    var layoutLineHeight: CGFloat {
        Self.lineHeight(for: storedFont)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if oldSize != newSize {
            needsDisplay = true
        }
    }

    public func heightThatFits(width: CGFloat) -> CGFloat {
        let usableWidth = max(1, width)
        ensureFramesetter(width: usableWidth)
        guard !storedText.isEmpty, let cachedFramesetter else { return 0 }
        let constraint = CGSize(
            width: usableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            cachedFramesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            nil
        )
        return ceil(suggested.height + storedOutlineWidth * 2)
    }

    func prepareLayoutCache() {
        let usableWidth = max(1, bounds.width)
        ensureFramesetter(width: usableWidth)
        let pathSize = CGSize(
            width: usableWidth,
            height: max(1, bounds.height)
        )
        guard cachedPath == nil || cachedPathSize != pathSize else { return }
        cachedPath = CGPath(rect: CGRect(origin: .zero, size: pathSize), transform: nil)
        cachedPathSize = pathSize
        identitySequence &+= 1
        cachedPathIdentity = identitySequence
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !storedText.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        prepareLayoutCache()
        guard let cachedFramesetter, let cachedPath else { return }

        let fillFrame = CTFramesetterCreateFrame(
            cachedFramesetter,
            CFRange(location: 0, length: 0),
            cachedPath,
            nil
        )
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        if let cachedOutlineFramesetter {
            let outlineFrame = CTFramesetterCreateFrame(
                cachedOutlineFramesetter,
                CFRange(location: 0, length: 0),
                cachedPath,
                nil
            )
            CTFrameDraw(outlineFrame, context)
        }
        CTFrameDraw(fillFrame, context)
        context.restoreGState()
    }

    private func ensureFramesetter(width: CGFloat) {
        let key = FramesetterKey(
            text: storedText,
            fontName: storedFont.fontName,
            fontSize: storedFont.pointSize,
            textColor: Self.components(storedTextColor),
            outlineColor: Self.components(storedOutlineColor),
            outlineWidth: storedOutlineWidth,
            alignment: storedAlignment,
            width: width
        )
        guard cachedFramesetter == nil || cachedKey != key else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = storedAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let lineHeight = Self.lineHeight(for: storedFont)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let strokePercentage = storedOutlineWidth > 0
            ? storedOutlineWidth / max(1, storedFont.pointSize) * 100
            : 0
        let commonAttributes: [NSAttributedString.Key: Any] = [
            .font: storedFont,
            .paragraphStyle: paragraph
        ]
        var fillAttributes = commonAttributes
        fillAttributes[.foregroundColor] = storedTextColor
        let attributed = NSAttributedString(
            string: storedText,
            attributes: fillAttributes
        )
        cachedAttributedText = attributed
        cachedFramesetter = CTFramesetterCreateWithAttributedString(attributed)
        if storedOutlineWidth > 0 {
            var outlineAttributes = commonAttributes
            outlineAttributes[.foregroundColor] = storedTextColor
            outlineAttributes[.strokeColor] = storedOutlineColor
            outlineAttributes[.strokeWidth] = strokePercentage
            let outline = NSAttributedString(
                string: storedText,
                attributes: outlineAttributes
            )
            cachedOutlineAttributedText = outline
            cachedOutlineFramesetter = CTFramesetterCreateWithAttributedString(
                outline
            )
        } else {
            cachedOutlineAttributedText = nil
            cachedOutlineFramesetter = nil
        }
        cachedKey = key
        cachedPath = nil
        cachedPathSize = nil
        cachedPathIdentity = nil
        cacheBuildCount += 1
        identitySequence &+= 1
        cachedFramesetterIdentity = identitySequence
    }

    private func invalidateTextLayout() {
        cachedKey = nil
        cachedFramesetter = nil
        cachedOutlineFramesetter = nil
        cachedPath = nil
        cachedPathSize = nil
        cachedAttributedText = nil
        cachedOutlineAttributedText = nil
        cachedFramesetterIdentity = nil
        cachedPathIdentity = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        let naturalLineHeight = font.ascender
            - font.descender
            + max(0, font.leading)
        return ceil(max(
            font.pointSize * 1.22,
            naturalLineHeight * 1.06
        ))
    }

    private static func components(_ color: NSColor) -> ColorComponents {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return ColorComponents(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return ColorComponents(
            red: rgb.redComponent,
            green: rgb.greenComponent,
            blue: rgb.blueComponent,
            alpha: rgb.alphaComponent
        )
    }
}
