import Foundation

private func observe(_ watchdog: inout NativeSpeechDrainProgress, _ now: Double,
                     received: Int = 1, played: Int = 0, buffer: Double = 1_000,
                     queued: Int = 0, preparing: Int = 0, active: Bool = false) -> NativeSpeechDrainProgress.Expiry? {
    watchdog.observe(now: now, receivedSequence: received, playedSequence: played,
        bufferedMilliseconds: buffer, queued: queued, preparing: preparing, synthesisActive: active)
}

private func healthyLongTails() {
    // One utterance lasting longer than the old total 60-second budget. Its
    // unchanged sequence and producer counts cannot hide real buffer drain.
    var watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, buffer: 66_000) == nil)
    for tick in 1...220 {
        let time = Double(tick) * 0.3
        assert(observe(&watchdog, time, played: tick == 220 ? 1 : 0,
                       buffer: max(0, 66_000 - time * 1_000)) == nil,
               "Healthy playback was cut off by total elapsed time")
    }

    // A healthy 90-second queue completes using the existing counters only.
    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, received: 20, buffer: 90_000, queued: 18, preparing: 2, active: true) == nil)
    for tick in 1...300 {
        let time = Double(tick) * 0.3
        let completed = tick == 300
        assert(observe(&watchdog, time, received: 20, played: completed ? 20 : min(19, tick / 15),
            buffer: max(0, 90_000 - time * 1_000), queued: completed ? 0 : max(0, 18 - tick / 15),
            preparing: completed ? 0 : 2, active: !completed) == nil)
    }
    assert(observe(&watchdog, 149.999, received: 20, played: 20, buffer: 0) == nil)
    assert(observe(&watchdog, 150, received: 20, played: 20, buffer: 0) == .stalled,
           "A quiet tail failed to expire after its last actual progress")

    // A delayed timer can still observe actual consumption since its preceding
    // snapshot. The observed progress renews inactivity, but never the hard cap.
    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, buffer: 90_000) == nil)
    assert(observe(&watchdog, 70, buffer: 20_000) == nil)
    assert(observe(&watchdog, 90, played: 1, buffer: 0) == nil)
}

private func inactivityAndRealProgress() {
    var watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0) == nil)
    for tick in 1..<200 { assert(observe(&watchdog, Double(tick) * 0.3) == nil) }
    assert(observe(&watchdog, 60) == .stalled)

    // The native render clock continues through silence, so it deliberately is
    // absent from this API. Buffer increases alone are equally uninformative.
    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0) == nil)
    for second in 1..<60 { assert(observe(&watchdog, Double(second), buffer: 1_000 + Double(second) * 100) == nil) }
    assert(observe(&watchdog, 60, buffer: 7_000) == .stalled)

    // Only a substantial decrease from the immediately preceding observation
    // renews inactivity; a series of tiny changes must not manufacture it.
    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, buffer: 1_000_000) == nil)
    for second in 1..<60 { assert(observe(&watchdog, Double(second), buffer: 1_000_000 - Double(second) * 99) == nil) }
    assert(observe(&watchdog, 60, buffer: 994_060) == .stalled)

    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, buffer: 1_000) == nil)
    assert(observe(&watchdog, 59, buffer: 900) == nil)
    assert(observe(&watchdog, 118.999, buffer: 900) == nil)
    assert(observe(&watchdog, 119, buffer: 900) == .stalled)

    // Each specified producer/player change independently renews the deadline.
    watchdog = NativeSpeechDrainProgress(now: 10)
    assert(observe(&watchdog, 10) == nil)
    assert(observe(&watchdog, 69, received: 2) == nil)
    assert(observe(&watchdog, 128, received: 2, played: 1) == nil)
    assert(observe(&watchdog, 187, received: 2, played: 1, queued: 1) == nil)
    assert(observe(&watchdog, 190, received: 2, played: 1, queued: 2) == .limit)

    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, preparing: 1, active: true) == nil)
    assert(observe(&watchdog, 59, preparing: 0, active: true) == nil)
    assert(observe(&watchdog, 118, preparing: 0, active: false) == nil)
    assert(observe(&watchdog, 177, preparing: 0, active: true) == nil)
    assert(observe(&watchdog, 180, preparing: 0, active: false) == .limit)

    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0, received: 4, played: 2) == nil)
    assert(observe(&watchdog, 30, received: 3, played: 1) == nil)
    assert(observe(&watchdog, 59, received: 4, played: 2) == nil)
    assert(observe(&watchdog, 60, received: 4, played: 2) == .stalled,
           "Regressed/replayed sequence counters created fake progress")
}

private func absoluteCap() {
    var watchdog = NativeSpeechDrainProgress(now: 100)
    assert(observe(&watchdog, 100, received: 1_000, buffer: 200_000) == nil)
    for tick in 1..<600 {
        let elapsed = Double(tick) * 0.3
        assert(observe(&watchdog, 100 + elapsed, received: 1_000, played: tick,
                       buffer: 200_000 - elapsed * 1_000) == nil)
    }
    assert(observe(&watchdog, 280, received: 1_001, played: 600, buffer: 1_000,
                   queued: 1, preparing: 1, active: true) == .limit,
           "Progress renewed the absolute native drain cap")
    assert(observe(&watchdog, 281, buffer: .nan) == .limit)
}

private func invalidObservations() {
    var watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0) == nil)
    assert(observe(&watchdog, 59) == nil)
    assert(observe(&watchdog, 10, received: 2, played: 1, buffer: 0, queued: 1, active: true) == nil)
    assert(observe(&watchdog, .nan, received: 2, played: 1, buffer: 0) == nil)
    assert(observe(&watchdog, .infinity, received: 2, played: 1, buffer: 0) == nil)
    assert(observe(&watchdog, -1, received: 2, played: 1, buffer: 0) == nil)
    assert(observe(&watchdog, 60) == .stalled,
           "Invalid/regressed clocks renewed a progress deadline")

    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0) == nil)
    assert(observe(&watchdog, 50, received: 2, played: 1, buffer: .nan, queued: 1, active: true) == nil)
    assert(observe(&watchdog, 55, received: 2, played: 1, buffer: .infinity, preparing: 1) == nil)
    assert(observe(&watchdog, 59, received: -1, buffer: -100) == nil)
    assert(observe(&watchdog, 60, buffer: .nan) == .stalled,
           "Invalid metrics prevented a valid clock from expiring")

    watchdog = NativeSpeechDrainProgress(now: 0)
    assert(observe(&watchdog, 0) == nil)
    assert(observe(&watchdog, 59, played: 2) == nil)
    assert(observe(&watchdog, 60, queued: -1) == .stalled)

    // A missing initial clock starts both budgets at the first valid reading.
    watchdog = NativeSpeechDrainProgress(now: .nan)
    assert(observe(&watchdog, .infinity) == nil)
    assert(observe(&watchdog, 100) == nil)
    assert(observe(&watchdog, 159.999) == nil)
    assert(observe(&watchdog, 160) == .stalled)
}

@main struct NativeSpeechDrainProgressChecks {
    static func main() {
        healthyLongTails()
        inactivityAndRealProgress()
        absoluteCap()
        invalidObservations()
        print("PASS: healthy 66/90-second native drains, observed progress, 60-second stalls, absolute 180-second cap and invalid-metric fencing")
    }
}
