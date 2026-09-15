import Foundation
import Darwin

// Developer-only acceptance executable. Never included in the shipped App.
// It uses synthetic consent exclusively in an explicitly marked, isolated fixture.
private struct BootstrapArguments {
    let resources: URL
    let dataHome: URL
    let cancelPrepareAndRetry: Bool
    let checkReadyOnly: Bool
    let timeoutSeconds: UInt64

    static let usage = "DesktopBootstrapAcceptance --resources <absolute payload folder> --data-home <absolute fixture folder> --fixture-required [--cancel-prepare-and-retry] [--check-ready-only] [--timeout-seconds 900]"

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:], flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if ["--fixture-required", "--cancel-prepare-and-retry", "--check-ready-only"].contains(key) {
                guard flags.insert(key).inserted else { throw BootstrapFailure("Duplicate option: " + key) }
            } else if ["--resources", "--data-home", "--timeout-seconds"].contains(key) {
                index += 1
                guard index < arguments.count, values[key] == nil else { throw BootstrapFailure("Missing or duplicate option: " + key) }
                values[key] = arguments[index]
            } else { throw BootstrapFailure("Unknown option: " + key + ". " + Self.usage) }
            index += 1
        }
        guard flags.contains("--fixture-required") else { throw BootstrapFailure("Synthetic test consent requires --fixture-required.") }
        guard let resourcePath = values["--resources"], resourcePath.hasPrefix("/"),
              let homePath = values["--data-home"], homePath.hasPrefix("/") else {
            throw BootstrapFailure("Explicit absolute resources and fixture data-home paths are required. " + Self.usage)
        }
        resources = URL(fileURLWithPath: resourcePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        dataHome = URL(fileURLWithPath: homePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        cancelPrepareAndRetry = flags.contains("--cancel-prepare-and-retry")
        checkReadyOnly = flags.contains("--check-ready-only")
        guard !(cancelPrepareAndRetry && checkReadyOnly) else { throw BootstrapFailure("Cancellation and readiness-only modes are mutually exclusive.") }
        guard let seconds = UInt64(values["--timeout-seconds"] ?? "900"), (5...7200).contains(seconds) else {
            throw BootstrapFailure("Timeout must be between 5 and 7200 seconds.")
        }
        timeoutSeconds = seconds
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoxHalo", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard dataHome.path != production, !dataHome.path.hasPrefix(production + "/") else {
            throw BootstrapFailure("The real VoxHalo data directory cannot be used as an acceptance fixture.")
        }
        let marker = dataHome.appendingPathComponent(".voxhalo-bootstrap-fixture.json")
        guard let bytes = try? Data(contentsOf: marker),
              let record = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              record["purpose"] as? String == "desktop-bootstrap-acceptance",
              record["synthetic_license_consent"] as? Bool == true else {
            throw BootstrapFailure("Fixture marker required: .voxhalo-bootstrap-fixture.json with purpose=desktop-bootstrap-acceptance and synthetic_license_consent=true.")
        }
        // Offline reuse should be a copy/clone inside this fixture, never a symlink
        // to a user's managed assets that a repair run could modify.
        for child in ["assets", "versions"] {
            let path = dataHome.appendingPathComponent(child).resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(dataHome.path + "/") else {
                throw BootstrapFailure("Fixture " + child + " must remain inside the fixture directory.")
            }
        }
    }
}

private struct BootstrapFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func emit(_ record: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

@MainActor private final class BootstrapRun {
    let installation: DesktopInstallation
    private let number: Int
    private var continuation: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastSignature = ""
    private(set) var requestedCancellation = false
    private(set) var timedOut = false
    private var cancelDuringPrepare = false

    init(installation: DesktopInstallation, number: Int) { self.installation = installation; self.number = number }
    func perform(cancelDuringPrepare: Bool, timeoutSeconds: UInt64) async {
        self.cancelDuringPrepare = cancelDuringPrepare
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            installation.onChange = { [weak self] in self?.changed() }
            installation.onSettled = { [weak self] in self?.settled() }
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000) }
                catch { return }
                guard let self, self.installation.isRunning else { return }
                self.timedOut = true
                emit(["event": "timeout", "run": self.number, "seconds": timeoutSeconds])
                self.installation.cancel()
            }
            emit(["event": "synthetic-fixture-consent", "run": number, "scope": "isolated acceptance fixture only"])
            installation.start(acceptedLicenses: true, territoryEligible: true)
            if !installation.isRunning { settled() }
        }
    }
    private func changed() {
        var record: [String: Any] = ["event": "state", "run": number, "state": String(describing: installation.state),
                                    "phase": installation.phase, "message": installation.message]
        if let event = installation.event {
            record["asset"] = event.asset
            record["completed_bytes"] = event.completedBytes
            record["total_bytes"] = event.totalBytes
            record["detail"] = event.message
        }
        let signature = String(describing: installation.state) + "|" + installation.phase + "|" +
            (installation.event?.asset ?? "") + "|" + String(installation.event?.completedBytes ?? -1) + "|" + installation.message
        if signature != lastSignature { lastSignature = signature; emit(record) }
        if cancelDuringPrepare, !requestedCancellation, installation.isRunning,
           installation.phase == "preparing", installation.event == nil {
            requestedCancellation = true
            emit(["event": "cancel-runtime-prepare", "run": number])
            installation.cancel()
        }
    }
    private func settled() {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        installation.onChange = nil; installation.onSettled = nil
        emit(["event": "settled", "run": number, "state": String(describing: installation.state),
              "ready": installation.isReady, "cancellation_requested": requestedCancellation, "timed_out": timedOut])
        if installation.state == .failed { emit(["event": "failure-details", "run": number, "details": installation.details]) }
        continuation.resume()
    }
}

@main struct DesktopBootstrapAcceptance {
    @MainActor static func main() async {
        do {
            let options = try BootstrapArguments(Array(CommandLine.arguments.dropFirst()))
            let installation = DesktopInstallation(resources: options.resources, dataHome: options.dataHome)
            guard let metadata = installation.metadata else { throw BootstrapFailure(installation.message + " " + installation.details) }
            let root = options.dataHome.appendingPathComponent("versions/" + metadata.version, isDirectory: true)
            emit(["event": "fixture", "resources": options.resources.path, "data_home": options.dataHome.path,
                  "version": metadata.version, "runtime_sha256": metadata.runtimeSHA256, "initial_ready": installation.isReady])
            if options.checkReadyOnly {
                emit(["event": "ready-check", "ready": installation.isReady, "version": metadata.version])
                guard installation.isReady else { throw BootstrapFailure("Ready marker or runtime payload hash did not match.") }
                return
            }
            guard FileManager.default.fileExists(atPath: options.resources.appendingPathComponent("runtime.tar.gz").path) else {
                throw BootstrapFailure("The updated runtime.tar.gz payload must exist before this acceptance run.")
            }
            if options.cancelPrepareAndRetry {
                guard !FileManager.default.fileExists(atPath: root.path) else {
                    throw BootstrapFailure("Cancel-during-prepare requires a fresh fixture version directory; this harness never deletes an existing version.")
                }
                let cancellation = BootstrapRun(installation: installation, number: 1)
                await cancellation.perform(cancelDuringPrepare: true, timeoutSeconds: options.timeoutSeconds)
                guard cancellation.requestedCancellation, !cancellation.timedOut, installation.state == .cancelled,
                      !FileManager.default.fileExists(atPath: root.appendingPathComponent("installed.json").path),
                      !metadata.hasInstalledRuntime(at: root) else {
                    throw BootstrapFailure("Cancellation did not settle before runtime publication, or left a ready marker.")
                }
                let versions = options.dataHome.appendingPathComponent("versions")
                let children = (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []
                guard !children.contains(where: { $0.hasPrefix(".stage-") }) else { throw BootstrapFailure("Cancelled runtime stage was not removed.") }
                emit(["event": "cancel-check", "passed": true, "retry": "same controller, retained fixture assets"])
            }
            let installationRun = BootstrapRun(installation: installation, number: options.cancelPrepareAndRetry ? 2 : 1)
            await installationRun.perform(cancelDuringPrepare: false, timeoutSeconds: options.timeoutSeconds)
            guard !installationRun.timedOut, installation.isReady, metadata.hasInstalledRuntime(at: root),
                  let marker = try? Data(contentsOf: root.appendingPathComponent("installed.json")), metadata.acceptsReadyMarker(marker) else {
                throw BootstrapFailure("The native controller did not finish with matching runtime and installation markers.")
            }
            let relaunched = DesktopInstallation(resources: options.resources, dataHome: options.dataHome)
            guard relaunched.isReady, relaunched.serviceRoot == installation.serviceRoot else {
                throw BootstrapFailure("A fresh native controller did not recognize the completed installation.")
            }
            emit(["event": "acceptance", "passed": true, "ready": true, "relaunch_ready": true,
                  "service_root": installation.serviceRoot!.path, "version": metadata.version,
                  "manifest_sha256": metadata.manifestSHA256, "runtime_sha256": metadata.runtimeSHA256,
                  "log": installation.logURL.path])
        } catch {
            emit(["event": "acceptance", "passed": false, "error": String(describing: error)])
            exit(1)
        }
    }
}
