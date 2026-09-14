import Foundation
@main struct HLSPlaybackBootstrapChecks {
    static func main() {
        let header = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n"
        let segment = "#EXTINF:1.024000,\nsegment.ts\n"
        precondition(!HLSPlaybackBootstrap.isReady(header + segment), "one segment can strand AVPlayer in unknown status")
        precondition(!HLSPlaybackBootstrap.isReady(header + segment + segment))
        precondition(HLSPlaybackBootstrap.isReady(header + String(repeating: segment,count:3)))
        precondition(!HLSPlaybackBootstrap.isReady(header.replacingOccurrences(of:":1",with:":2") + String(repeating:segment,count:3)), "use target duration, not a fixed segment count")
        precondition(HLSPlaybackBootstrap.isReady(header.replacingOccurrences(of:":1",with:":2") + String(repeating:segment,count:6)))
        precondition(!HLSPlaybackBootstrap.isReady(""))
        precondition(!HLSPlaybackBootstrap.isReady("#EXT-X-TARGETDURATION:0\n#EXTINF:nan,\n"))
        print("PASS: cold HLS bootstrap waits for three target durations")
    }
}
