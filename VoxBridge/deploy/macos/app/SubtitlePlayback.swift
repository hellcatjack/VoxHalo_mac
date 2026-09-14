import Foundation

/// Read-only presentation of the existing audio schedule. Never schedules, trims,
/// synthesizes or waits on speech; newer translations cannot move this clock.
enum SubtitlePlayback {
    struct Caption: Equatable {
        let text: String
        let identity: CompletedSubtitleState.Identity
    }
    static func pcm(_ schedule: [[String: Any]], presentedFrame: Int64?) -> Caption? {
        guard let presentedFrame, presentedFrame >= 0 else { return nil }
        for chunk in schedule.reversed() {
            guard let start = (chunk["start_frame"] as? NSNumber)?.int64Value, start <= presentedFrame,
                  let text = chunk["text"] as? String, !text.isEmpty,
                  let sentence = chunk["sentence_id"] as? String,
                  let revision = chunk["revision"] as? Int,
                  let sequence = chunk["seq"] as? Int else { continue }
            return Caption(text: text, identity: .init(sentenceID: sentence, revision: revision, speechSequence: sequence))
        }
        return nil
    }
}
