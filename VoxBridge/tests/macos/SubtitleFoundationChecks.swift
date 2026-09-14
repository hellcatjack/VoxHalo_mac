import CoreGraphics
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private func source(_ type: String = "sentence_committed", id: String, revision: Int, text: String) -> [String: Any] {
    ["type": type, "sentence_id": id, "revision": revision, "text": text]
}

private func translation(id: String, revision: Int, text: Any, stable: Any = true,
                         type: String = "sentence_translation") -> [String: Any] {
    ["type": type, "sentence_id": id, "revision": revision, "translation": text, "is_stable": stable]
}

private func checkCompletedSubtitleState() throws {
    var state = CompletedSubtitleState()
    try expect(state.text.isEmpty, "new subtitle state must be empty")

    state.observe(source(id: "zh-1", revision: 1, text: "早上好"))
    try expect(state.text.isEmpty, "source ASR text must never be displayed")
    state.observe(translation(id: "zh-1", revision: 1, text: "Good morning", stable: false))
    state.observe(translation(id: "zh-1", revision: 1, text: "Good", stable: true, type: "translation_partial"))
    state.observe(translation(id: "zh-1", revision: 1, text: " morning", stable: true, type: "translation_delta"))
    state.observe(translation(id: "zh-1", revision: 1, text: "aggregate", stable: true, type: "translation_final"))
    state.observe(["type": "error", "text": "backend failure"])
    try expect(state.text.isEmpty, "partial, aggregate, and error events must not leak into subtitles")
    state.observe(translation(id: "zh-1", revision: 1, text: "Good morning"))
    try expect(state.text == "Good morning", "a stable matching translation must be displayed")

    state.observe(source("sentence_updated", id: "zh-1", revision: 2, text: "大家早上好"))
    try expect(state.text.isEmpty, "a displayed sentence revision must clear its old translation")
    state.observe(translation(id: "zh-1", revision: 1, text: "stale"))
    try expect(state.text.isEmpty, "a stale translation revision must be ignored")
    state.observe(translation(id: "zh-1", revision: 2, text: "Good morning, everyone"))
    try expect(state.text == "Good morning, everyone", "the latest matching revision must display")
    state.observe(translation(id: "zh-1", revision: 2, text: ""))
    try expect(state.text == "Good morning, everyone", "an empty completed translation must not erase the subtitle")
    state.observe(translation(id: "missing", revision: 1, text: "unknown"))
    try expect(state.text == "Good morning, everyone", "an unknown sentence translation must be ignored")

    state.observe(source(id: "old", revision: 1, text: "旧句"))
    state.observe(source(id: "new", revision: 1, text: "新句"))
    state.observe(translation(id: "new", revision: 1, text: "New sentence"))
    state.observe(translation(id: "old", revision: 1, text: "Old sentence arrived late"))
    try expect(state.text == "New sentence", "a late older sentence must not overwrite a newer completed sentence")

    let previousIdentity = state.identity
    state.observe(source(id: "repeat", revision: 1, text: "新句"))
    state.observe(translation(id: "repeat", revision: 1, text: "New sentence"))
    try expect(state.text == "New sentence" && state.identity != previousIdentity, "a repeated sentence needs a new presentation identity")

    var sameRevision = CompletedSubtitleState()
    sameRevision.observe(source(id: "same", revision: 7, text: "first source"))
    sameRevision.observe(translation(id: "same", revision: 7, text: "First translation"))
    sameRevision.observe(source("sentence_updated", id: "same", revision: 7, text: "changed source"))
    try expect(sameRevision.text.isEmpty, "changed source text at the same revision must clear the displayed translation")
    sameRevision.observe(source("sentence_updated", id: "same", revision: 6, text: "older source"))
    sameRevision.observe(translation(id: "same", revision: 6, text: "Older translation"))
    try expect(sameRevision.text.isEmpty, "older source and translation revisions must stay ignored")

    var english = CompletedSubtitleState()
    english.observe(source(id: "en-1", revision: 1, text: "Welcome to church"))
    english.observe(translation(id: "en-1", revision: 1, text: "欢迎来到教会"))
    try expect(english.text == "欢迎来到教会", "English-to-Chinese completed text must preserve Unicode")
    english.observe(["type": "started"])
    try expect(english.text.isEmpty, "started must reset transient subtitle state")
    english.observe(source(id: "again", revision: 1, text: "再次"))
    english.observe(translation(id: "again", revision: 1, text: "Again"))
    english.observe(["type": "sentence_reset"])
    try expect(english.text.isEmpty, "sentence_reset must reset transient subtitle state")
    english.observe(source(id: "manual", revision: 1, text: "手动"))
    english.observe(translation(id: "manual", revision: 1, text: "Manual"))
    english.reset()
    try expect(english.text.isEmpty, "explicit reset must clear transient subtitle state")

    var strict = CompletedSubtitleState()
    strict.observe(source(id: "strict", revision: 1, text: "严格"))
    strict.observe(translation(id: "strict", revision: 1, text: "numeric", stable: 1))
    strict.observe(translation(id: "strict", revision: 1, text: "string", stable: "true"))
    strict.observe(translation(id: "strict", revision: 1, text: 42))
    try expect(strict.text.isEmpty, "is_stable and translation must have strict Bool and String types")

    var bounded = CompletedSubtitleState()
    for index in 0...300 {
        bounded.observe(source(id: "id-\(index)", revision: 1, text: "source \(index)"))
    }
    bounded.observe(translation(id: "id-0", revision: 1, text: "evicted"))
    try expect(bounded.text.isEmpty, "source metadata must evict the oldest entry beyond 300")
    bounded.observe(translation(id: "id-1", revision: 1, text: "retained"))
    try expect(bounded.text == "retained", "the newest 300 source entries must remain usable")

    var evictedDisplay = CompletedSubtitleState()
    evictedDisplay.observe(source(id: "displayed", revision: 1, text: "original"))
    evictedDisplay.observe(translation(id: "displayed", revision: 1, text: "Visible"))
    for index in 1...300 {
        evictedDisplay.observe(source(id: "later-\(index)", revision: 1, text: "later"))
    }
    evictedDisplay.observe(source("sentence_updated", id: "displayed", revision: 2, text: "corrected"))
    try expect(evictedDisplay.text.isEmpty,
               "a correction for the displayed ID must clear text even after its bounded metadata was evicted")
}

private func checkSubtitlePreferences() throws {
    let defaults = SubtitlePreferences()
    try expect(defaults.enabled && defaults.fontName == "PingFangSC-Semibold" && defaults.fontSize == 36,
               "subtitle appearance defaults changed")
    try expect(defaults.textColorHex == "#FFFFFF" && defaults.shadowEnabled && defaults.shadowColorHex == "#000000",
               "subtitle color defaults changed")
    try expect(defaults.shadowOpacity == 0.9 && defaults.shadowBlur == 4 && defaults.shadowOffset == 2,
               "subtitle shadow defaults changed")
    try expect(defaults.screenID.isEmpty && defaults.horizontalPosition == 0.5 && defaults.verticalPosition == 0.88 && defaults.widthFraction == 0.8,
               "subtitle placement defaults changed")

    var untrusted = SubtitlePreferences()
    untrusted.fontName = "   "
    untrusted.fontSize = .infinity
    untrusted.textColorHex = "#a0b1c2"
    untrusted.shadowColorHex = "not-a-color"
    untrusted.shadowOpacity = -4
    untrusted.shadowBlur = 80
    untrusted.shadowOffset = .nan
    untrusted.horizontalPosition = -0.2
    untrusted.verticalPosition = 1.8
    untrusted.widthFraction = 0.1
    untrusted.screenID = String(repeating: "s", count: 250)
    let normalized = untrusted.normalized()
    try expect(normalized.fontName == "PingFangSC-Semibold" && normalized.fontSize == 36,
               "invalid font values must use safe defaults")
    try expect(normalized.textColorHex == "#A0B1C2" && normalized.shadowColorHex == "#000000",
               "RGB colors must uppercase or fall back independently")
    try expect(normalized.shadowOpacity == 0 && normalized.shadowBlur == 30 && normalized.shadowOffset == 2,
               "shadow numbers must be finite and clamped independently")
    try expect(normalized.horizontalPosition == 0 && normalized.verticalPosition == 1 && normalized.widthFraction == 0.25,
               "placement numbers must be clamped")
    try expect(normalized.screenID.count == 200, "stable screen IDs must be bounded")
    var longFont = SubtitlePreferences()
    longFont.fontName = String(repeating: "字", count: 201)
    try expect(longFont.normalized().fontName.count == 200, "font names must be bounded by characters")

    let suiteName = "subtitle-foundation-" + UUID().uuidString
    guard let storage = UserDefaults(suiteName: suiteName) else { throw CheckFailure.failed("could not create isolated UserDefaults") }
    defer { storage.removePersistentDomain(forName: suiteName) }
    storage.set(Data(##"{"enabled":false,"fontName":"Avenir","fontSize":"bad","textColorHex":"#abcdef","shadowEnabled":false,"shadowOpacity":0.25,"verticalPosition":0.4,"unknown":1}"##.utf8),
                forKey: "subtitlePreferences")
    storage.set(Data("unrelated".utf8), forKey: "nativeAudioPreferences")
    let tolerant = SubtitlePreferences.load(from: storage)
    try expect(!tolerant.enabled && tolerant.fontName == "Avenir", "valid decoded fields must survive a corrupt sibling field")
    try expect(tolerant.fontSize == 36 && tolerant.textColorHex == "#ABCDEF", "invalid decoded fields must default without discarding valid fields")
    try expect(!tolerant.shadowEnabled && tolerant.shadowOpacity == 0.25 && tolerant.verticalPosition == 0.4,
               "partial preferences must retain each valid field")
    try expect(tolerant.shadowColorHex == "#000000" && tolerant.screenID.isEmpty,
               "missing decoded fields must receive defaults")

    var saved = SubtitlePreferences()
    saved.enabled = false
    saved.fontName = "Helvetica Neue"
    saved.fontSize = 160
    saved.screenID = "display-uuid"
    try saved.save(to: storage)
    let loaded = SubtitlePreferences.load(from: storage)
    try expect(loaded.enabled == false && loaded.fontName == "Helvetica Neue" && loaded.fontSize == 144 && loaded.screenID == "display-uuid",
               "save/load must round-trip normalized preferences under the subtitle key")
    try expect(storage.data(forKey: "nativeAudioPreferences") == Data("unrelated".utf8),
               "subtitle persistence must not overwrite native audio preferences")
}

private func checkFrameGeometry() throws {
    let centered = SubtitlePreferences.frame(in: CGRect(x: 100, y: 200, width: 1000, height: 800),
                                               size: CGSize(width: 200, height: 100), horizontal: 0.5, vertical: 0.5)
    try expect(centered == CGRect(x: 500, y: 550, width: 200, height: 100),
               "center placement must use the inset screen area")
    let topLeft = SubtitlePreferences.frame(in: CGRect(x: -1200, y: -200, width: 800, height: 600),
                                              size: CGSize(width: 300, height: 80), horizontal: 0, vertical: 0)
    try expect(topLeft == CGRect(x: -1180, y: 320, width: 300, height: 80),
               "top-left placement must support negative display origins")
    let bottomRight = SubtitlePreferences.frame(in: CGRect(x: -1200, y: -200, width: 800, height: 600),
                                                  size: CGSize(width: 300, height: 80), horizontal: 1, vertical: 1)
    try expect(bottomRight == CGRect(x: -720, y: -200, width: 300, height: 80),
               "bottom-right placement must reach the full screen bottom")
    let huge = SubtitlePreferences.frame(in: CGRect(x: 10, y: 20, width: 100, height: 80),
                                           size: CGSize(width: 1_000_000, height: 1_000_000), horizontal: 0.3, vertical: 0.7)
    try expect(huge == CGRect(x: 30, y: 20, width: 60, height: 80),
               "huge content must clamp to the full height and horizontal safe inset")
    let tiny = SubtitlePreferences.frame(in: CGRect(x: 5, y: 7, width: 30, height: 10),
                                           size: CGSize(width: 100, height: 100), horizontal: 1, vertical: 1)
    try expect(tiny.origin == CGPoint(x: 20, y: 7) && tiny.width == 0 && tiny.height == 10,
               "small screens must clamp each inset without escaping the screen")
    let malformed = SubtitlePreferences.frame(in: CGRect(x: CGFloat.nan, y: -CGFloat.infinity, width: CGFloat.infinity, height: -10),
                                                size: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
                                                horizontal: Double.nan, vertical: Double.infinity)
    try expect(malformed == .zero, "non-finite or negative geometry must return finite bounded geometry")
    let overflow = SubtitlePreferences.frame(
        in: CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                   width: CGFloat.greatestFiniteMagnitude, height: 100),
        size: CGSize(width: 20, height: 20), horizontal: 1, vertical: 1
    )
    try expect(overflow == .zero, "finite inputs whose screen bounds overflow must return safe geometry")
}

@main struct SubtitleFoundationChecks {
    static func main() throws {
        try checkCompletedSubtitleState()
        try checkSubtitlePreferences()
        try checkFrameGeometry()
        print("Subtitle state, preference, persistence, and geometry checks passed")
    }
}
