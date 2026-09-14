import Foundation

@main struct HLSPlaybackGapChecks {
    static func main() throws {
        let previous = HLSPlaybackGap.Cue(id: "one", start: 1000, end: 3000, discardable: 0, resume: nil)
        let next = HLSPlaybackGap.Cue(id: "two", start: 9000, end: 12000, discardable: 5600, resume: 8600)
        func target(_ at: Double, _ ranges: [ClosedRange<Double>] = [0...20], _ cues: [HLSPlaybackGap.Cue] = [previous, next]) -> HLSPlaybackGap.Target? {
            HLSPlaybackGap.target(cues: cues, playheadMs: at, mediaTime: at / 1000, seekable: ranges)
        }
        assert(target(2500) == nil, "never skip the preceding sentence")
        assert(abs(target(3000)!.mediaTime - 8.6) < 0.001, "retain 400ms of natural pause")
        assert(abs(target(3200)!.mediaTime - 8.75) < 0.001, "retain at least 250ms AAC lead-in")
        assert(target(8700) == nil, "tiny seeks are slower than finishing a short pause")
        assert(target(9000) == nil, "never seek inside the next sentence")
        assert(target(3000, [0...8.9]) == nil, "the next speech must already be seekable")
        assert(target(3000, [0...8.65, 8.8...20]) == nil, "do not jump across disjoint ranges")
        assert(target(.nan) == nil)
        assert(target(3000, [0...20], [next]) == nil, "no preceding speech means no confirmed gap")
        let malformed = HLSPlaybackGap.Cue(id: "bad", start: 9000, end: 12000, discardable: 5600, resume: 2000)
        assert(target(3000, [0...20], [previous, malformed]) == nil)
        let exaggerated = HLSPlaybackGap.Cue(id: "mismatch", start: 9000, end: 12000, discardable: 500, resume: 8600)
        assert(target(3000, [0...20], [previous, exaggerated]) == nil, "inconsistent metadata must not remove natural silence")
        let overlap = HLSPlaybackGap.Cue(id: "overlap", start: 500, end: 6000, discardable: 0, resume: nil)
        assert(target(4000, [0...20], [overlap, previous, next]) == nil, "an older overlapping speech cue must prevent a skip")
        let ordinary = HLSPlaybackGap.Cue(id: "ordinary", start: 9000, end: 12000, discardable: 0, resume: nil)
        assert(target(3000, [0...20], [previous, ordinary]) == nil, "never shorten unmarked natural pauses")
        let invalidEnd = HLSPlaybackGap.Cue(id: "invalid", start: 9000, end: 8000, discardable: 5600, resume: 8600)
        assert(target(3000, [0...20], [previous, invalidEnd]) == nil)
        let json = Data("{\"cue_id\":\"two\",\"start_at_ms\":9000,\"end_at_ms\":12000,\"discardable_gap_before_ms\":5600,\"resume_at_ms\":8600,\"text\":\"hello\"}".utf8)
        let decoded = try JSONDecoder().decode(HLSPlaybackGap.Cue.self, from: json)
        assert(decoded.id == "two" && decoded.text == "hello")
        print("PASS: only confirmed carrier silence is skipped; speech, natural pause and seekable guards preserved")
    }
}
