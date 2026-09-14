import Foundation

@main struct MicrophoneRecoveryChecks {
    static func main() throws {
        var running = true
        try MicrophoneReconfiguration.recover(deviceAvailable: true, isRunning: running) {
            preconditionFailure("A late startup notification must not interrupt a running engine")
        }
        precondition(running)
        running = false
        try MicrophoneReconfiguration.recover(deviceAvailable: true, isRunning: running) { running = true }
        precondition(running, "A configuration change must recover the selected microphone")
        do {
            try MicrophoneReconfiguration.recover(deviceAvailable: false, isRunning: true) {
                preconditionFailure("An unplugged device must never fall back to another microphone")
            }
            preconditionFailure("Missing input was accepted")
        } catch { precondition(error.localizedDescription.contains("断开")) }
        do {
            try MicrophoneReconfiguration.recover(deviceAvailable: true, isRunning: false) {
                throw NativeAudioError.message("test restart failure")
            }
            preconditionFailure("Restart error was swallowed")
        } catch { precondition(error.localizedDescription.contains("test restart failure")) }
        print("PASS: startup notification / stopped-engine recovery / disconnected input / restart failure")
    }
}
