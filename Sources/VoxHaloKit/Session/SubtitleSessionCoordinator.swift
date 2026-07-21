import Foundation

public actor SubtitleSessionCoordinator: SubtitleSessionCoordinating {
    public private(set) var state: SubtitleSessionState = .stopped
    public private(set) var currentSubtitle: SubtitleDisplayModel

    private let client: any VoxBridgeClientProtocol
    private let capture: any AudioCapturing
    private let sourceValidator: any AudioSourceValidating
    private let permissionProvider: any AudioPermissionProviding
    private let queue: BoundedAudioFrameQueue
    private let diagnostics: any DiagnosticsLogging
    private let clock: any SessionClock
    private let policy: SubtitleSessionPolicy
    private let endpointValidator: SubtitleSessionEndpointValidator

    private var store: SubtitleStateStore
    private var outputContinuation: AsyncStream<SubtitleSessionOutput>.Continuation?
    private var clientOutputTask: Task<Void, Never>?
    private var audioDrainTask: Task<Void, Never>?
    private var queueGeneration: UInt64?
    private var activeConfiguration: SubtitleSessionConfiguration?
    private var sessionToken: UInt64 = 0
    private var captureWasStarted = false
    private var backendFaulted = false
    private var audioOverloadReported = false
    private var sentFrameCount: UInt64 = 0

    public init(
        client: any VoxBridgeClientProtocol,
        capture: any AudioCapturing,
        sourceValidator: any AudioSourceValidating,
        permissionProvider: any AudioPermissionProviding,
        queue: BoundedAudioFrameQueue,
        store: SubtitleStateStore,
        diagnostics: any DiagnosticsLogging,
        clock: any SessionClock = ContinuousSessionClock(),
        policy: SubtitleSessionPolicy = SubtitleSessionPolicy(),
        endpointValidator: @escaping SubtitleSessionEndpointValidator = {
            try VoxBridgeEndpoint(validating: $0.webSocketURL)
        }
    ) {
        self.client = client
        self.capture = capture
        self.sourceValidator = sourceValidator
        self.permissionProvider = permissionProvider
        self.queue = queue
        self.store = store
        self.currentSubtitle = store.current
        self.diagnostics = diagnostics
        self.clock = clock
        self.policy = policy
        self.endpointValidator = endpointValidator
    }

    public func outputs() async -> AsyncStream<SubtitleSessionOutput> {
        outputContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubtitleSessionOutput.self
        )
        outputContinuation = continuation
        return stream
    }

    public func start(
        _ configuration: SubtitleSessionConfiguration
    ) async throws {
        guard state == .stopped else {
            throw SubtitleSessionError.alreadyActive
        }

        sessionToken &+= 1
        let token = sessionToken
        transition(to: .starting)
        var startupStage = StartupStage.endpointValidation
        var connected = false
        var captureAttempted = false
        var generation: UInt64?

        do {
            let endpoint = try endpointValidator(configuration.endpoint)
            try ensureStarting(token)

            startupStage = .sourceValidation
            try sourceValidator.validateAvailable(configuration.audioSource)
            try ensureStarting(token)

            startupStage = .permission
            try await permissionProvider.authorize(configuration.audioSource)
            try ensureStarting(token)

            let validatedConfiguration = SubtitleSessionConfiguration(
                endpoint: endpoint,
                direction: configuration.direction,
                audioSource: configuration.audioSource,
                credentials: configuration.credentials
            )
            activeConfiguration = validatedConfiguration
            await installClientOutputTask(token: token)
            try ensureStarting(token)

            startupStage = .connect
            do {
                try await client.connect(
                    to: endpoint,
                    credentials: configuration.credentials
                )
                connected = true
            } catch {
                connected = await client.isConnected
                throw error
            }
            try ensureStarting(token)

            store.reset(direction: configuration.direction)
            currentSubtitle = store.current
            publish(.subtitle(currentSubtitle))

            startupStage = .startMessage
            try await client.start(direction: configuration.direction)
            try ensureStarting(token)

            startupStage = .audioCapture
            let activeGeneration = queue.reset()
            generation = activeGeneration
            queueGeneration = activeGeneration
            audioDrainTask = makeAudioDrainTask(
                generation: activeGeneration,
                token: token
            )
            captureAttempted = true
            captureWasStarted = true
            try await capture.start(
                source: configuration.audioSource,
                onFrame: { [queue] frame in
                    queue.offer(frame, generation: activeGeneration)
                },
                onFailure: { [weak self, queue] failure in
                    if failure == .pipelineOverloaded {
                        queue.signalOverflow(generation: activeGeneration)
                    }
                    Task {
                        await self?.handleCaptureFailure(
                            failure,
                            generation: activeGeneration,
                            token: token
                        )
                    }
                }
            )
            try ensureStarting(token)

            await diagnostics.record(.sessionStart(
                host: endpoint.webSocketURL.host ?? "unknown",
                port: Self.effectivePort(for: endpoint),
                direction: configuration.direction,
                username: configuration.credentials?.username,
                deviceID: configuration.audioSource.id,
                deviceName: configuration.audioSource.name
            ))
            await diagnostics.record(.capture(category: "started"))
            try ensureStarting(token)
            transition(to: .running)
        } catch {
            await rollbackStart(
                token: token,
                connected: connected,
                captureAttempted: captureAttempted,
                generation: generation
            )
            await diagnostics.record(.failure(category: startupStage.category))
            publish(.failure(Self.failureMessage(for: error)))
            if state != .stopped {
                transition(to: .stopped)
            }
            throw error
        }
    }

    public func stop() async {
        guard state != .stopped else { return }

        sessionToken &+= 1
        transition(to: .finishing)
        if captureWasStarted {
            await capture.stop()
            captureWasStarted = false
        }
        await endAudioDrain()
        await cancelClientOutputTask()
        if await client.isConnected {
            await client.disconnect()
        }
        clearSessionResources()
        transition(to: .stopped)
    }

    private func installClientOutputTask(token: UInt64) async {
        await cancelClientOutputTask()
        let stream = await client.outputs()
        clientOutputTask = Task { [weak self] in
            for await output in stream {
                guard !Task.isCancelled else { return }
                await self?.handleClientOutput(output, token: token)
            }
        }
    }

    private func makeAudioDrainTask(
        generation: UInt64,
        token: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self, queue] in
            while !Task.isCancelled, let event = await queue.next() {
                guard let self else { return }
                await self.handleAudioQueueEvent(
                    event,
                    generation: generation,
                    token: token
                )
            }
        }
    }

    private func handleAudioQueueEvent(
        _ event: AudioFrameQueueEvent,
        generation: UInt64,
        token: UInt64
    ) async {
        guard token == sessionToken,
              generation == queueGeneration,
              state == .starting || state == .running else {
            return
        }

        switch event {
        case let .frame(frame):
            do {
                try await client.sendAudioFrame(frame.pcm16LE)
                guard token == sessionToken,
                      generation == queueGeneration else { return }
                sentFrameCount &+= 1
                if sentFrameCount <= 3 || sentFrameCount.isMultiple(of: 50) {
                    await diagnostics.record(.audio(
                        frameCount: sentFrameCount,
                        byteCount: frame.pcm16LE.count
                    ))
                }
            } catch {
                backendFaulted = true
                await diagnostics.record(.failure(category: "audio_send"))
            }

        case .overflow:
            backendFaulted = true
            if !audioOverloadReported {
                audioOverloadReported = true
                publish(.status("Audio pipeline overloaded"))
                await diagnostics.record(.failure(category: "audio_overload"))
            }
        }
    }

    private func handleClientOutput(
        _ output: VoxBridgeClientOutput,
        token: UInt64
    ) async {
        guard token == sessionToken,
              state == .starting || state == .running || state == .finishing else {
            return
        }

        switch output {
        case let .event(event):
            await recordBackendDiagnostic(event)
            guard token == sessionToken else { return }

            if Self.updatesSubtitle(event.type) {
                currentSubtitle = store.apply(event)
                publish(.subtitle(currentSubtitle))
            }

            if event.type == .error {
                backendFaulted = true
                if let message = Self.conciseBackendMessage(event.message) {
                    publish(.status(message))
                }
            }

        case let .connection(connection):
            switch connection {
            case .connected:
                await diagnostics.record(.connection(category: "connected"))
                publish(.status("Connected"))
            case .disconnected:
                backendFaulted = true
                await diagnostics.record(.connection(category: "disconnected"))
                publish(.status("Disconnected"))
            case .parseError:
                await diagnostics.record(.failure(category: "parse_error"))
                publish(.status("Receive parse error"))
            case .receiveError:
                backendFaulted = true
                await diagnostics.record(.failure(category: "receive_error"))
                publish(.status("Receive error"))
            }
        }
    }

    private func recordBackendDiagnostic(_ event: VoxBridgeEvent) async {
        let transcript = Self.firstNonBlank([
            event.text,
            event.tentativeText,
            event.stateText,
            event.committedText,
            event.deltaText
        ])
        let translation = Self.trimmed(event.translation)
        await diagnostics.record(.backend(
            type: event.rawType,
            sequence: event.sequence ?? event.stability?.sequence,
            textLength: transcript?.utf16.count ?? 0,
            translationLength: translation?.utf16.count ?? 0,
            stability: event.stability,
            transcript: transcript,
            translation: translation
        ))
    }

    private func handleCaptureFailure(
        _ failure: AudioCaptureFailure,
        generation: UInt64,
        token: UInt64
    ) async {
        guard token == sessionToken,
              generation == queueGeneration,
              state == .running else {
            return
        }
        if failure == .pipelineOverloaded {
            return
        }

        await diagnostics.record(.failure(category: "capture_runtime"))
        publish(.failure(Self.failureMessage(for: failure)))
        await stopAfterCaptureFailure(token: token)
    }

    private func stopAfterCaptureFailure(token: UInt64) async {
        guard token == sessionToken else { return }
        sessionToken &+= 1
        if captureWasStarted {
            await capture.stop()
            captureWasStarted = false
        }
        await endAudioDrain()
        await cancelClientOutputTask()
        await client.disconnect()
        clearSessionResources()
        transition(to: .stopped)
    }

    private func rollbackStart(
        token: UInt64,
        connected: Bool,
        captureAttempted: Bool,
        generation: UInt64?
    ) async {
        if captureAttempted {
            await capture.stop()
            captureWasStarted = false
        }
        if let generation {
            queue.finish(generation: generation)
        }
        if let audioDrainTask {
            audioDrainTask.cancel()
            await audioDrainTask.value
            self.audioDrainTask = nil
        }
        queueGeneration = nil
        await cancelClientOutputTask()
        let clientIsConnected = await client.isConnected
        if connected || clientIsConnected {
            await client.disconnect()
        }
        if token == sessionToken {
            clearSessionResources()
        }
    }

    private func endAudioDrain() async {
        if let queueGeneration {
            queue.finish(generation: queueGeneration)
        }
        if let audioDrainTask {
            audioDrainTask.cancel()
            await audioDrainTask.value
        }
        audioDrainTask = nil
        queueGeneration = nil
    }

    private func cancelClientOutputTask() async {
        if let clientOutputTask {
            clientOutputTask.cancel()
            await clientOutputTask.value
        }
        clientOutputTask = nil
    }

    private func clearSessionResources() {
        activeConfiguration = nil
        backendFaulted = false
        audioOverloadReported = false
        sentFrameCount = 0
        captureWasStarted = false
    }

    private func transition(to nextState: SubtitleSessionState) {
        state = nextState
        publish(.state(nextState))
    }

    private func publish(_ output: SubtitleSessionOutput) {
        outputContinuation?.yield(output)
    }

    private func ensureStarting(_ token: UInt64) throws {
        guard token == sessionToken, state == .starting else {
            throw CancellationError()
        }
    }

    private static func updatesSubtitle(_ type: VoxBridgeEventType) -> Bool {
        switch type {
        case .partial, .sentenceCommitted, .sentenceUpdated,
             .sentenceTranslation, .sentenceReset, .processing, .final:
            true
        case .unknown, .ready, .started, .translationDirection, .error, .pong:
            false
        }
    }

    private static func effectivePort(for endpoint: VoxBridgeEndpoint) -> Int {
        if let port = endpoint.webSocketURL.port { return port }
        return endpoint.isInsecure ? 80 : 443
    }

    private static func firstNonBlank(_ values: [String?]) -> String? {
        for value in values {
            if let value = trimmed(value) { return value }
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func conciseBackendMessage(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        return String(value.prefix(256))
    }

    private static func failureMessage(for error: Error) -> String {
        switch error {
        case let error as VoxBridgeEndpointError:
            error.localizedDescription
        case let error as VoxBridgeAuthenticationError:
            error.localizedDescription
        case let error as VoxBridgeClientError:
            error.localizedDescription
        case let error as AudioCaptureFailure:
            audioFailureMessage(error)
        case is CancellationError:
            "Subtitle startup was cancelled."
        default:
            "Unable to start subtitles."
        }
    }

    private static func audioFailureMessage(
        _ failure: AudioCaptureFailure
    ) -> String {
        switch failure {
        case .microphonePermissionDenied:
            "Microphone access is required for this audio source."
        case .systemAudioPermissionDenied:
            "System Audio Recording access is required."
        case .deviceUnavailable:
            "The selected audio source is unavailable."
        case .deviceDisconnected:
            "The selected audio source was disconnected."
        case .pipelineOverloaded:
            "Audio pipeline overloaded"
        case .unsupportedFormat:
            "The selected audio format is unsupported."
        case .coreAudio:
            "Audio capture could not be started."
        }
    }

    private enum StartupStage {
        case endpointValidation
        case sourceValidation
        case permission
        case connect
        case startMessage
        case audioCapture

        var category: String {
            switch self {
            case .endpointValidation: "endpoint_validation"
            case .sourceValidation: "source_validation"
            case .permission: "permission"
            case .connect: "connect"
            case .startMessage: "start_message"
            case .audioCapture: "audio_capture"
            }
        }
    }
}
