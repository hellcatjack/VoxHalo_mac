import AppKit

private func source(_ id: String, revision: Any = 1, text: String? = nil) -> [String: Any] {
    ["type": "sentence_committed", "sentence_id": id, "revision": revision, "text": text ?? id]
}
private func translation(_ id: String, _ text: String, revision: Any = 1, stable: Any = true) -> [String: Any] {
    ["type": "sentence_translation", "sentence_id": id, "revision": revision, "translation": text, "is_stable": stable]
}
private func speech(_ id: String, _ text: String, order: Any, revision: Any = 2, index: Any = 0) -> [String: Any] {
    ["sentence_id": id, "sentence_text": text, "text": "Chunk fragment.",
     "source_order": order, "revision": revision, "index": index, "count": 2]
}

private func checkSpeechSupplements() {
    var history = SubtitleHistory()
    history.observe(source("parent", text: "Full original parent sentence"))
    history.observe(translation("parent", "The completed parent omits the year."))
    history.observe(source("later", text: "Later original sentence"))
    history.observe(translation("later", "Later translation."))
    let parent = speech("parent", "The spoken parent.", order: 10, revision: 1)
    let supplement = speech("parent:addition:2", "The exact spoken supplement says 2030.", order: 11)
    history.observeSpeech([parent, supplement])
    assert(history.entries.map { $0.translation } == ["The completed parent omits the year.",
        "The exact spoken supplement says 2030.", "Later translation."])
    assert(history.entries[1].source.isEmpty && history.entries[1].id == "speech:0:11:parent:addition:2",
           "Preserve supplemental speech near its parent without mislabeling the full parent as its source delta")
    let unchanged = history.entries, version = history.version
    history.observeSpeech([parent, supplement, speech("parent:addition:2", "A later partial chunk.", order: 11, index: 1)])
    history.observeSpeech([speech("parent:addition:2", "A changed retransmission must not replace accepted speech.", order: 11)])
    assert(history.entries == unchanged && history.version == version, "Snapshots and later chunks must not duplicate or rewrite a supplement")
    history.observeSpeech([speech("later:addition:2", supplement["sentence_text"] as! String, order: 13)])
    assert(history.entries.count == 4 && history.entries.last?.source.isEmpty == true,
           "The same spoken words at another source occurrence must be retained")
    history.observe(["type": "sentence_reset", "reason": "final_redecode"])
    history.observeSpeech([parent, supplement])
    assert(history.entries.count == 4, "Ledger reset must not replay old accepted schedule snapshots")
    history.observeSpeech([speech("later:addition:3", "Late supplemental audio after ledger reset.", order: 14, revision: 3)])
    assert(history.entries.last?.id == "speech:0:14:later:addition:3", "A saved raw parent binding must survive ledger reset")
    history.observe(source("parent", text: "Reconstructed parent"))
    history.observe(translation("parent", "Reconstructed translation."))
    history.observeSpeech([speech("parent", "New parent speech.", order: 20, revision: 1),
        speech("parent:addition:3", "Old parent's late supplement.", order: 12, revision: 3),
        speech("parent:addition:2", supplement["sentence_text"] as! String, order: 21)])
    assert(history.entries[2].id == "speech:0:12:parent:addition:3",
           "PCM order must bind old speech to the earlier occurrence when raw parent IDs are reused")
    assert(history.entries.last?.id == "speech:1:21:parent:addition:2", "A reused supplement ID at a new occurrence must stay")
    history.observeSpeech([speech("reset-1:parent:addition:4", "History-ID-bound supplement.", order: 22, revision: 4)])
    assert(history.entries.last?.id == "speech:1:22:reset-1:parent:addition:4", "Saved history identities must resolve defensively")
    history.observeSpeech([speech("unbound:addition:2", "An accepted supplement with no known source.", order: 90)])
    assert(history.entries.last?.source == "" && history.entries.last?.translation == "An accepted supplement with no known source.")
    let validCount = history.entries.count
    history.observeSpeech([speech("parent", "Ordinary speech is already recorded via WS.", order: 30),
        speech("parent:addition:5", " \n\t", order: 31),
        speech("parent:addition:5", "Invalid index.", order: 31, index: false),
        speech("parent:addition:5", "Invalid revision.", order: 31, revision: 1.5),
        speech("parent:addition:5", "Invalid order.", order: true)])
    assert(history.entries.count == validCount)
    history.observe(["type": "sentence_reset", "reason": "final_commit_reconcile"])
    history.observeSpeech([supplement])
    assert(history.entries.count == validCount && history.entries.contains { $0.translation.contains("2030") })
    history.reset(); history.observeSpeech([supplement])
    assert(history.entries.count == 1, "New-session reset must clear accepted-speech deduplication")
    print("PASS: exact accepted speech supplements, parent grouping, ordinary-speech exclusion, snapshot/chunk deduplication and ledger-reset retention")
}

private func checkHistory() {
    var history = SubtitleHistory()
    history.observe(source("first", text: "原文一")); history.observe(source("second", text: "原文二"))
    history.observe(translation("second", "Second.")); history.observe(translation("first", "First."))
    assert(history.entries.map { $0.id } == ["first", "second"], "Completion order must not reorder source occurrences")
    let completed = history.entries, version = history.version
    history.observe(translation("first", "First."))
    assert(history.entries == completed && history.version == version, "Identical retransmission must not add an entry")
    history.observe(translation("first", "First corrected."))
    assert(history.entries.map { $0.translation } == ["First.", "First corrected.", "Second."], "Same-revision corrections must preserve both versions")
    history.observe(["type": "sentence_updated", "sentence_id": "first", "revision": 2, "text": "原文一校订"])
    assert(history.entries.count == 3 && history.entries[0].source == "原文一", "An untranslated revision must retain completed history")
    history.observe(translation("first", "Obsolete.", revision: 1))
    history.observe(translation("first", "Draft.", revision: 2, stable: false))
    assert(history.entries.count == 3)
    history.observe(translation("first", "Revised.", revision: 2))
    assert(history.entries[2].revision == 2 && history.entries[2].source == "原文一校订")
    history.observe(source("repeat", text: "原文二")); history.observe(translation("repeat", "Second."))
    assert(history.entries.count == 5 && history.entries.last?.id == "repeat", "A real repeated occurrence must stay")
    history.observe(translation("unknown", "Unbound."))
    history.observe(translation("repeat", " \n\t"))
    history.observe(translation("repeat", "Unconfirmed.", stable: 1))
    history.observe(translation("repeat", "String Boolean.", stable: "true"))
    history.observe(translation("repeat", "Boolean revision.", revision: true))
    history.observe(translation("repeat", "Fractional revision.", revision: 1.5))
    assert(history.entries.count == 5)
    for invalid: Any in [true, -1, 1.5, "1", Double.infinity, Double.nan, NSNumber(value: UInt64.max)] {
        history.observe(source("invalid", revision: invalid))
        history.observe(translation("invalid", "Must not appear.", revision: invalid))
    }
    assert(history.entries.count == 5, "Invalid revision metadata must never create a record")
    history.observe(source("repeat", revision: 0, text: "obsolete source"))
    history.observe(translation("repeat", "Late correct value."))
    assert(history.entries.last?.source == "原文二", "A stale source event must not replace the source mapping")
    history.reset()
    assert(history.entries.isEmpty && history.version > version)
    for index in 0..<750 {
        let id = "retained-\(index)"
        history.observe(source(id)); history.observe(translation(id, "完整译文 \(index) 🌿\nSecond line."))
    }
    assert(history.entries.count == 750 && history.entries.first?.id == "retained-0" && history.entries.last?.id == "retained-749")
    let previousEntries = history.entries, previousVersion = history.version
    history.observe(["type": "sentence_reset", "reason": "final_redecode"])
    assert(history.entries == previousEntries && history.version == previousVersion,
           "An in-session final re-decode must retain completed history")
    history.observe(translation("retained-0", "Unbound old result."))
    assert(history.entries.count == 750, "Ledger reset must discard obsolete source bindings")
    history.observe(source("retained-0", revision: 2))
    history.observe(translation("retained-0", previousEntries[0].translation, revision: 2))
    assert(history.entries.count == 751 && history.entries.last?.id != previousEntries[0].id,
           "A reused source ID must be a new history occurrence after ledger reset")
    history.observe(source("retained-0", revision: 3, text: "Reconstructed correction"))
    history.observe(translation("retained-0", "New complete correction.", revision: 3))
    assert(history.entries.count == 752 && history.entries.prefix(750).elementsEqual(previousEntries))
    history.observe(["type": "sentence_reset", "reason": "final_commit_reconcile"])
    history.observe(source("retained-0")); history.observe(translation("retained-0", previousEntries[0].translation))
    assert(history.entries.count == 753 && Set(history.entries.map { $0.id }).count == 752,
           "Repeated resets must preserve separate occurrences while grouping revisions")
    history.observe(["type": "started"])
    assert(history.entries.isEmpty)
    history.observe(translation("retained-0", "Old session."))
    assert(history.entries.isEmpty, "New session must discard all previous source bindings")
    history.observe(source("new")); history.observe(translation("new", "New session."))
    assert(history.entries.count == 1 && history.entries[0].id == "new")
    print("PASS: source order, completed corrections, stale/draft validation, deduplication, real repeats, 750-entry retention, in-session ledger epochs and new-session reset")
}

@MainActor private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

@MainActor private func checkWindow() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let controller = SubtitleHistoryWindow()
    var history = SubtitleHistory()
    controller.show(history: history)
    guard let window = NSApp.windows.first(where: { $0.title == NativeLocalization.text("阅读记录") }),
          let content = window.contentView,
          let view = descendants(content).compactMap({ $0 as? NSTextView }).first,
          let scroll = descendants(content).compactMap({ $0 as? NSScrollView }).first else { fatalError("Missing native history window") }
    assert(view.isSelectable && !view.isEditable && view.string == NativeLocalization.text("本次传译尚无完整译文。"))
    history.observe(source("early", text: "Earlier source"))
    for index in 0..<80 {
        history.observe(source("row-\(index)", text: "Source \(index)"))
        history.observe(translation("row-\(index)", "Translation \(index) 🌿."))
    }
    controller.update(history: history)
    await settleHistory()
    assert(view.string.contains("1. Source 0\nTranslation 0 🌿.") && view.string.contains("80. Source 79"))
    let selected = (view.string as NSString).range(of: "Translation 25 🌿.")
    view.setSelectedRange(selected)
    view.scrollRangeToVisible(selected)
    scroll.reflectScrolledClipView(scroll.contentView)
    let before = scroll.contentView.bounds.origin.y
    assert(before > 0 && scroll.contentView.bounds.maxY < view.bounds.maxY - 4)
    history.observe(source("appended", text: "Appended source")); history.observe(translation("appended", "Appended translation."))
    controller.update(history: history)
    await settleHistory()
    assert(view.selectedRange() == selected && abs(scroll.contentView.bounds.origin.y - before) < 1,
           "Appending history must preserve selection and a reader's scroll position: \(view.selectedRange()) versus \(selected), scroll \(scroll.contentView.bounds.origin.y) versus \(before)")
    history.observe(translation("early", "Earlier translation."))
    controller.update(history: history)
    await settleHistory()
    assert((view.string as NSString).substring(with: view.selectedRange()) == "Translation 25 🌿.",
           "A late earlier translation must preserve the selected entry")
    let currentSelection = view.selectedRange(), currentScroll = scroll.contentView.bounds.origin.y
    controller.refreshLocalization(history: history)
    await settleHistory()
    assert(view.selectedRange() == currentSelection && abs(scroll.contentView.bounds.origin.y - currentScroll) < 1)
    assert(view.string.hasPrefix("1. Earlier source\nEarlier translation."))
    history.observeSpeech([speech("early:addition:2", "Supplemental 2030 text.", order: 5)])
    controller.update(history: history)
    await settleHistory()
    assert(view.string.contains(NativeLocalization.text("朗读补充") + "\nSupplemental 2030 text."))
    assert((view.string as NSString).substring(with: view.selectedRange()) == "Translation 25 🌿.",
           "Adding a translation-only supplement above the selected passage must preserve selection")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: view.bounds.maxY - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    history.observe(source("last")); history.observe(translation("last", "Last full translation."))
    controller.update(history: history)
    await settleHistory()
    assert(abs(scroll.contentView.bounds.maxY - view.bounds.maxY) < 1, "A reader already at the end may continue following new entries")
    let oldPassage = (view.string as NSString).range(of: "Translation 25 🌿.")
    view.setSelectedRange(oldPassage); view.scrollRangeToVisible(oldPassage)
    let retainedScroll = scroll.contentView.bounds.origin.y
    history.observe(["type": "sentence_reset", "reason": "final_redecode"])
    history.observe(source("row-25", text: "Source 25"))
    history.observe(translation("row-25", "Translation 25 🌿."))
    controller.update(history: history)
    await settleHistory()
    assert(view.selectedRange() == oldPassage && abs(scroll.contentView.bounds.origin.y - retainedScroll) < 1,
           "Reused source IDs after ledger reset must not move selection to the reconstructed occurrence")
    let closedBody = view.string, closedFrame = view.frame
    window.close()
    assert(!window.isVisible)
    for index in 0..<12 {
        history.observe(source("closed-\(index)", text: "Closed source \(index)"))
        history.observe(translation("closed-\(index)", "Closed translation \(index)."))
        controller.update(history: history)
    }
    window.title = "Deferred localization"
    controller.refreshLocalization(history: history)
    assert(view.string == closedBody && view.frame == closedFrame && window.title == "Deferred localization",
           "Closed history updates/localization must defer text reconstruction and layout")
    controller.show(history: history)
    assert(window.isVisible && window.title == NativeLocalization.text("阅读记录"))
    for index in 0..<12 { assert(view.string.contains("Closed source \(index)\nClosed translation \(index).")) }
    assert(view.selectedRange() == oldPassage && abs(scroll.contentView.bounds.origin.y - retainedScroll) < 1,
           "Reopening must render every deferred entry while preserving the prior reading anchor")
    let beforeBurst = view.string, renders = controller.renderCountForTesting
    for index in 0..<40 {
        history.observe(source("burst-\(index)")); history.observe(translation("burst-\(index)", "Burst translation \(index)."))
        controller.update(history: history)
    }
    assert(view.string == beforeBurst && controller.renderCountForTesting == renders,
           "A burst of history events must not synchronously block caption updates with text layout")
    await settleHistory()
    assert(controller.renderCountForTesting == renders + 1 && view.string.contains("Burst translation 39."),
           "Coalescing must retain and render every latest record in one deferred update")
    assert(view.selectedRange() == oldPassage && abs(scroll.contentView.bounds.origin.y - retainedScroll) < 1,
           "Deferred burst rendering must preserve the reader's selection and scroll anchor")
    history.reset(); controller.update(history: history)
    await settleHistory()
    assert(view.string == NativeLocalization.text("本次传译尚无完整译文。"))
    window.close()
    print("PASS: native selectable history, numbering, append/insertion anchors, deferred closed-window rendering, localization refresh and bottom following")
}

@MainActor private func settleHistory() async {
    try? await Task.sleep(nanoseconds: 300_000_000)
}

@main struct SubtitleHistoryChecks {
    @MainActor static func main() async {
        checkHistory(); checkSpeechSupplements(); await checkWindow()
    }
}
