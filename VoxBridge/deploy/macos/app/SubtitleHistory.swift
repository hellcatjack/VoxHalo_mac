import AppKit

/// A full current-session record, independent of live captions and speech.
struct SubtitleHistory {
    struct Entry: Equatable {
        let id: String
        let revision: Int
        let source: String
        let translation: String
    }
    private struct SourceGroup {
        let rawID: String
        let epoch: Int
        let order: Int
        let historyID: String
    }
    private struct Source {
        let group: SourceGroup
        var revision: Int
        var text: String
        var order: Int { group.order }
        var historyID: String { group.historyID }
    }
    private struct SpeechKey: Hashable {
        let id: String
        let order: Int
        let revision: Int
    }
    private var sources: [String: Source] = [:]
    private var sourceGroups: [String: [SourceGroup]] = [:]
    private var speechBindings: [SpeechKey: SourceGroup] = [:]
    private var recordedSpeech: Set<SpeechKey> = []
    private var sourceEpoch = 0
    private var nextOrder = 0
    private var entryOrders: [Int] = []
    private(set) var entries: [Entry] = []
    private(set) var version = 0

    mutating func reset() {
        sources.removeAll(); entries.removeAll(); entryOrders.removeAll()
        sourceGroups.removeAll(); speechBindings.removeAll(); recordedSpeech.removeAll()
        nextOrder = 0; sourceEpoch = 0
        version &+= 1
    }

    mutating func observe(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "started": reset()
        case "sentence_reset":
            // Final re-decode/reconciliation rebuilds the ledger within the same
            // session. Completed records survive, even if source IDs are reused.
            sources.removeAll(); sourceEpoch &+= 1
        case "sentence_committed", "sentence_updated":
            guard let id = event["sentence_id"] as? String, !id.isEmpty,
                  let revision = Self.revision(event["revision"]),
                  let text = event["text"] as? String else { return }
            if var source = sources[id] {
                guard revision >= source.revision else { return }
                source.revision = revision; source.text = text; sources[id] = source
            } else {
                let historyID = sourceEpoch == 0 ? id : "reset-\(sourceEpoch):\(id)"
                let group = SourceGroup(rawID: id, epoch: sourceEpoch, order: nextOrder, historyID: historyID)
                sources[id] = Source(group: group, revision: revision, text: text)
                sourceGroups[id, default: []].append(group)
                nextOrder += 1
            }
        case "sentence_translation":
            guard let stable = event["is_stable"] as? NSNumber,
                  CFGetTypeID(stable) == CFBooleanGetTypeID(), stable.boolValue,
                  let id = event["sentence_id"] as? String,
                  let revision = Self.revision(event["revision"]),
                  let translation = event["translation"] as? String,
                  !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let source = sources[id], source.revision == revision,
                  !entries.contains(where: { $0.id == source.historyID && $0.revision == revision && $0.translation == translation }) else { return }
            let entry = Entry(id: source.historyID, revision: revision, source: source.text, translation: translation)
            // Late translations and corrections stay beside their source occurrence.
            let insertion = entryOrders.firstIndex { $0 > source.order } ?? entries.endIndex
            entries.insert(entry, at: insertion); entryOrders.insert(source.order, at: insertion)
            version &+= 1
        default: break
        }
    }

    /// Retain exact accepted supplemental speech that has no ordinary stable
    /// translation row. Reading this schedule never controls or changes audio.
    mutating func observeSpeech(_ schedule: [[String: Any]]) {
        // Remember ordinary parent PCM bindings without adding ordinary history.
        // These distinguish late old speech from a reused ID after ledger reset.
        for value in schedule {
            guard let key = Self.speechKey(value), !key.id.contains(":addition:"),
                  speechBindings[key] == nil, let group = group(for: key.id) else { continue }
            speechBindings[key] = group
        }
        for value in schedule {
            guard let key = Self.speechKey(value), !recordedSpeech.contains(key),
                  let marker = key.id.range(of: ":addition:", options: .backwards),
                  marker.lowerBound > key.id.startIndex, marker.upperBound < key.id.endIndex,
                  let text = value["sentence_text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let parent = String(key.id[..<marker.lowerBound])
            let bound = speechBindings.filter { binding, group in
                binding.order < key.order && (binding.id == parent || group.historyID == parent)
            }.max { $0.key.order < $1.key.order }?.value ?? group(for: parent)
            let order: Int
            if let bound { order = bound.order; speechBindings[key] = bound }
            else { order = nextOrder; nextOrder += 1 }
            let id = "speech:\(bound?.epoch ?? sourceEpoch):\(key.order):\(key.id)"
            // The full parent source is not the original delta. The schedule
            // supplies translated speech only, so leave the source unassigned.
            let entry = Entry(id: id, revision: key.revision, source: "", translation: text)
            let insertion = entryOrders.firstIndex { $0 > order } ?? entries.endIndex
            entries.insert(entry, at: insertion); entryOrders.insert(order, at: insertion)
            recordedSpeech.insert(key); version &+= 1
        }
    }

    private func group(for id: String) -> SourceGroup? {
        sources[id]?.group ?? sourceGroups[id]?.last
            ?? sourceGroups.values.flatMap { $0 }.last { $0.historyID == id }
    }

    private static func speechKey(_ value: [String: Any]) -> SpeechKey? {
        guard let id = value["sentence_id"] as? String, !id.isEmpty,
              let revisionValue = revision(value["revision"]),
              let order = revision(value["source_order"]),
              revision(value["index"]) == 0 else { return nil }
        return SpeechKey(id: id, order: order, revision: revisionValue)
    }

    private static func revision(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        let integer = number.int64Value
        guard integer >= 0, number.compare(NSNumber(value: integer)) == .orderedSame,
              integer <= Int64(Int.max) else { return nil }
        return Int(integer)
    }
}

/// Native selectable reading history. It observes presentation data only.
@MainActor final class SubtitleHistoryWindow {
    private struct Anchor {
        let entry: SubtitleHistory.Entry
        let offset: Int
        let fromTranslation: Bool
    }
    private var window: NSWindow?
    private let intro = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var renderedEntries: [SubtitleHistory.Entry] = []
    private var renderedRanges: [NSRange] = []
    private var renderedVersion: Int?
    private var renderedLocale = ""

    init() {}

    func show(history: SubtitleHistory) {
        if window == nil { build() }
        render(history: history)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(history: SubtitleHistory) {
        // A closed, hidden or minimized history must not rebuild/layout a full
        // transcript on the main thread while live captions and audio continue.
        guard let window, window.isVisible, !window.isMiniaturized else { return }
        render(history: history)
    }

    private func render(history: SubtitleHistory) {
        guard let window else { return }
        let locale = NativeLocalization.locale
        guard renderedVersion != history.version || renderedEntries != history.entries || renderedLocale != locale else { return }
        window.title = NativeLocalization.text("阅读记录")
        intro.stringValue = NativeLocalization.text("保留本次传译的完整译文与校订记录；实时字幕按朗读进度显示。")
        textView.setAccessibilityLabel(NativeLocalization.text("阅读记录"))
        window.contentView?.layoutSubtreeIfNeeded()

        let oldOrigin = scroll.contentView.bounds.origin
        let followBottom = renderedVersion != nil && scroll.contentView.bounds.maxY >= textView.bounds.maxY - 4
        let selections = textView.selectedRanges.map { $0.rangeValue }
        let selectionAnchors = selections.map { (anchor(at: $0.location), anchor(at: NSMaxRange($0))) }
        let topIndex = character(at: oldOrigin)
        let topAnchor = anchor(at: topIndex)
        let topOffset = oldOrigin.y - characterY(topIndex)

        var body = "", ranges: [NSRange] = [], bodyLength = 0
        for (index, entry) in history.entries.enumerated() {
            if !body.isEmpty { body += "\n\n"; bodyLength += 2 }
            let heading = entry.source.isEmpty
                ? (entry.id.hasPrefix("speech:") ? NativeLocalization.text("朗读补充") : "") : entry.source
            let part = "\(index + 1). " + (heading.isEmpty ? "" : heading + "\n") + entry.translation
            let length = part.utf16.count
            ranges.append(NSRange(location: bodyLength, length: length))
            body += part; bodyLength += length
        }
        if body.isEmpty { body = NativeLocalization.text("本次传译尚无完整译文。") }
        textView.string = body
        renderedEntries = history.entries; renderedRanges = ranges
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let height = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        textView.setFrameSize(NSSize(width: scroll.contentSize.width,
                                    height: max(scroll.contentSize.height, ceil(height + 2 * textView.textContainerInset.height))))

        let length = (body as NSString).length
        textView.selectedRanges = selections.enumerated().map { index, selection in
            let start = position(of: selectionAnchors[index].0) ?? min(selection.location, length)
            let end = position(of: selectionAnchors[index].1) ?? min(NSMaxRange(selection), length)
            return NSValue(range: NSRange(location: min(start, end), length: abs(end - start)))
        }
        let y: CGFloat
        if followBottom { y = textView.bounds.maxY - scroll.contentView.bounds.height }
        else if let position = position(of: topAnchor) { y = characterY(position) + topOffset }
        else { y = oldOrigin.y }
        let maximum = max(0, textView.bounds.maxY - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: oldOrigin.x, y: min(maximum, max(0, y))))
        scroll.reflectScrolledClipView(scroll.contentView)
        renderedVersion = history.version; renderedLocale = locale
    }

    func refreshLocalization(history: SubtitleHistory) {
        renderedLocale = ""; update(history: history)
    }

    private func anchor(at position: Int) -> Anchor? {
        guard let index = renderedRanges.lastIndex(where: { $0.location <= position }) else { return nil }
        let translationStart = NSMaxRange(renderedRanges[index]) - renderedEntries[index].translation.utf16.count
        if position >= translationStart {
            return Anchor(entry: renderedEntries[index], offset: min(position, NSMaxRange(renderedRanges[index])) - translationStart,
                          fromTranslation: true)
        }
        let prefix = "\(index + 1). ".utf16.count
        return Anchor(entry: renderedEntries[index], offset: min(renderedRanges[index].length, position - renderedRanges[index].location) - prefix,
                      fromTranslation: false)
    }

    private func position(of anchor: Anchor?) -> Int? {
        guard let anchor, let index = renderedEntries.firstIndex(of: anchor.entry) else { return nil }
        if anchor.fromTranslation {
            // A localized supplement label can change length while its accepted
            // translation remains immutable. Keep the reader on that text.
            let length = renderedEntries[index].translation.utf16.count
            return NSMaxRange(renderedRanges[index]) - length + min(anchor.offset, length)
        }
        let prefix = "\(index + 1). ".utf16.count
        return renderedRanges[index].location + prefix + max(-prefix, min(anchor.offset, renderedRanges[index].length - prefix))
    }

    private func character(at point: NSPoint) -> Int {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        return layout.characterIndex(for: NSPoint(x: max(0, point.x - textView.textContainerInset.width),
                                                  y: max(0, point.y - textView.textContainerInset.height)),
                                     in: container, fractionOfDistanceBetweenInsertionPoints: nil)
    }

    private func characterY(_ position: Int) -> CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              layout.numberOfGlyphs > 0 else { return 0 }
        let character = min(position, max(0, (textView.string as NSString).length - 1))
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minY
            + textView.textContainerInset.height
    }

    private func build() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 420, height: 300)
        panel.center(); window = panel
        guard let content = panel.contentView else { return }
        intro.font = .systemFont(ofSize: 12); intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.font = .systemFont(ofSize: 15); textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(NativeLocalization.text("阅读记录"))
        scroll.documentView = textView
        content.addSubview(intro); content.addSubview(scroll)
        NSLayoutConstraint.activate([
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        content.layoutSubtreeIfNeeded(); textView.setFrameSize(scroll.contentSize)
    }
}
