import Foundation
@testable import VoxHaloKit

actor RecordingDiagnosticsLogger: DiagnosticsLogging {
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

actor DisabledRecordingDiagnosticsLogger: DiagnosticsLogging {
    nonisolated let isEnabled = false
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

actor SessionOutputRecorder {
    private(set) var outputs: [SubtitleSessionOutput] = []

    func append(_ output: SubtitleSessionOutput) {
        outputs.append(output)
    }

    var states: [SubtitleSessionState] {
        outputs.compactMap {
            guard case let .state(value) = $0 else { return nil }
            return value
        }
    }

    var subtitles: [SubtitleDisplayModel] {
        outputs.compactMap {
            guard case let .subtitle(value) = $0 else { return nil }
            return value
        }
    }

    var failures: [String] {
        outputs.compactMap {
            guard case let .failure(value) = $0 else { return nil }
            return value
        }
    }

    var statuses: [String] {
        outputs.compactMap {
            guard case let .status(value) = $0 else { return nil }
            return value
        }
    }
}

struct SubtitleSessionFixture: Sendable {
    let calls: CallRecorder
    let client: FakeVoxBridgeClient
    let audio: FakeAudioCapture
    let permissions: FakeAudioPermissionProvider
    let sourceValidator: FakeAudioSourceValidator
    let diagnostics: RecordingDiagnosticsLogger
    let coordinator: SubtitleSessionCoordinator
    let configuration: SubtitleSessionConfiguration

    init(
        direction: TranslationDirection = .chineseToEnglish,
        source: AudioSource = .systemAudio,
        credentials: VoxBridgeAuthCredentials? = nil,
        endpointURL: URL = URL(string: "wss://example.test:18024/ws")!,
        initialStore: SubtitleStateStore? = nil,
        endpointError: (any Error & Sendable)? = nil,
        sourceError: (any Error & Sendable)? = nil,
        permissionError: (any Error & Sendable)? = nil,
        connectError: (any Error & Sendable)? = nil,
        clientStartError: (any Error & Sendable)? = nil,
        audioStartError: (any Error & Sendable)? = nil,
        audioFailureDuringStart: AudioCaptureFailure? = nil,
        finishError: (any Error & Sendable)? = nil,
        finishOutput: VoxBridgeClientOutput? = nil,
        sendFailureCount: Int = 0,
        sendsSuspended: Bool = false,
        connectSuspended: Bool = false,
        queueCapacity: Int = 4,
        clock: any SessionClock = ContinuousSessionClock(),
        policy: SubtitleSessionPolicy = SubtitleSessionPolicy(),
        diagnosticsOverride: (any DiagnosticsLogging)? = nil
    ) throws {
        let calls = CallRecorder()
        let client = FakeVoxBridgeClient(
            calls: calls,
            connectError: connectError,
            startError: clientStartError,
            finishError: finishError,
            finishOutput: finishOutput,
            sendFailureCount: sendFailureCount,
            sendsSuspended: sendsSuspended,
            connectSuspended: connectSuspended
        )
        let audio = FakeAudioCapture(
            calls: calls,
            startError: audioStartError,
            failureDuringStart: audioFailureDuringStart
        )
        let permissions = FakeAudioPermissionProvider(
            calls: calls,
            error: permissionError
        )
        let sourceValidator = FakeAudioSourceValidator(
            calls: calls,
            error: sourceError
        )
        let diagnostics = RecordingDiagnosticsLogger()
        let endpoint = try VoxBridgeEndpoint(validating: endpointURL)
        let configuration = SubtitleSessionConfiguration(
            endpoint: endpoint,
            direction: direction,
            audioSource: source,
            credentials: credentials
        )
        let store = initialStore ?? SubtitleStateStore(direction: direction)

        self.calls = calls
        self.client = client
        self.audio = audio
        self.permissions = permissions
        self.sourceValidator = sourceValidator
        self.diagnostics = diagnostics
        self.configuration = configuration
        coordinator = SubtitleSessionCoordinator(
            client: client,
            capture: audio,
            sourceValidator: sourceValidator,
            permissionProvider: permissions,
            queue: BoundedAudioFrameQueue(capacity: queueCapacity),
            store: store,
            diagnostics: diagnosticsOverride ?? diagnostics,
            clock: clock,
            policy: policy,
            endpointValidator: { endpoint in
                calls.record("validate:endpoint")
                if let endpointError { throw endpointError }
                return try VoxBridgeEndpoint(validating: endpoint.webSocketURL)
            }
        )
    }

    func recordOutputs() async -> (
        recorder: SessionOutputRecorder,
        task: Task<Void, Never>
    ) {
        let recorder = SessionOutputRecorder()
        let stream = await coordinator.outputs()
        let task = Task {
            for await output in stream {
                await recorder.append(output)
            }
        }
        return (recorder, task)
    }
}

func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return await predicate()
}

func sessionFrame(_ byte: UInt8, timestamp: UInt64 = 1) -> CapturedAudioFrame {
    CapturedAudioFrame(
        pcm16LE: Data(repeating: byte, count: VoxBridgePCMFormat.frameByteCount),
        callbackTimestamp: AudioCallbackTimestamp(
            nanosecondsSinceBoot: timestamp
        )
    )
}
