import Foundation

@main struct SubtitlePlaybackChecks {
    static func main() {
        let first: [String: Any] = ["seq": 1, "sentence_id": "s1", "revision": 1, "index": 0, "text": "First completed clause.", "start_frame": 2400, "end_frame": 48000]
        let second: [String: Any] = ["seq": 2, "sentence_id": "s2", "revision": 1, "index": 0, "text": "Second completed clause.", "start_frame": 48000, "end_frame": 72000]
        let schedule = [first, second]
        assert(SubtitlePlayback.pcm(schedule, presentedFrame: nil) == nil)
        assert(SubtitlePlayback.pcm(schedule, presentedFrame: -1) == nil)
        assert(SubtitlePlayback.pcm(schedule, presentedFrame: 2399) == nil)
        let showing = SubtitlePlayback.pcm(schedule, presentedFrame: 2400)!
        assert(showing.text == first["text"] as? String)
        assert(SubtitlePlayback.pcm(schedule, presentedFrame: 47999) == showing, "queued second sentence must not replace audio still being played")
        for _ in 0..<100 {
            assert(SubtitlePlayback.pcm(schedule, presentedFrame: 12000) == showing, "a stationary playback clock must hold the caption")
        }
        assert(SubtitlePlayback.pcm(schedule, presentedFrame: 48000)?.text == second["text"] as? String)
        assert(SubtitlePlayback.pcm(schedule, presentedFrame: 100000)?.text == second["text"] as? String, "retain the last spoken caption while starved")
        var repeated = second; repeated["sentence_id"] = "s1"; repeated["text"] = first["text"]
        assert(SubtitlePlayback.pcm([first, repeated], presentedFrame: 48000)?.identity != showing.identity)
        assert(SubtitlePlayback.pcm([], presentedFrame: 100000) == nil, "stopped/new sessions have no caption")
        print("PASS: playback-bound captions hold during queueing, pause and starvation; change at audio boundaries")
    }
}
