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
    private var outputSubscriptionID: UUID?
    private var clientOutputTask: Task<Void, Never>?
    private var audioDrainTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Error>?
    private var startupTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var queueGeneration: UInt64?
    private var activeConfiguration: SubtitleSessionConfiguration?
    private var captureFailureGate: CaptureFailureGate?
    private var finalSignalContinuation: AsyncStream<Void>.Continuation?
    private var finalSignalToken: UInt64?
    private var sessionToken: UInt64 = 0
    private var captureWasStarted = false
    private var backendFaulted = false
    private var backendSessionErrorMessage: String?
    private var backendStartRejectedMessage: String?
    private var runningStatus = "Running"
    private var audioOverloadReported = false
    private var sentFrameCount: UInt64 = 0
    private var lastAudioCallbackTimestamp: AudioCallbackTimestamp?

    var backendSessionIsFaulted: Bool { backendFaulted }

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
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubtitleSessionOutput.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeOutputSubscription(id) }
        }
        outputSubscriptionID = id
        outputContinuation = continuation
        return stream
    }

    public func start(
        _ configuration: SubtitleSessionConfiguration
    ) async throws {
        guard state == .stopped,
              startupTask == nil,
              stopTask == nil else {
            throw SubtitleSessionError.alreadyActive
        }

        resetBackendSessionFault()
        runningStatus = "Running"
        sessionToken &+= 1
        let token = sessionToken
        transition(to: .starting)
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStart(configuration, token: token)
        }
        startupTask = task
        try await task.value
    }

    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard state == .starting || state == .running else { return }

        let stoppedDuringStart = state == .starting
        let token = sessionToken
        let startupToWait = stoppedDuringStart ? startupTask : nil
        transition(to: .finishing)
        captureFailureGate?.deactivate()
        if stoppedDuringStart {
            sessionToken &+= 1
            startupToWait?.cancel()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStop(
                token: token,
                startupToWait: startupToWait,
                stoppedDuringStart: stoppedDuringStart
            )
        }
        stopTask = task
        await task.value
    }

    private func performStart(
        _ configuration: SubtitleSessionConfiguration,
        token: UInt64
    ) async throws {
        defer { completeStartup(token: token) }
        var startupStage = StartupStage.endpointValidation
        var connected = false
        var captureAttempted = false

        do {
            let endpoint = try endpointValidator(configuration.endpoint)
            try ensureStarting(token)

            startupStage = .sourceValidation
            try sourceValidator.validateAvailable(configuration.audioSource)
            try ensureStarting(token)

            startupStage = .permission
            try await permissionProvider.authorize(configuration.audioSource)
            try ensureStarting(token)

            activeConfiguration = SubtitleSessionConfiguration(
                endpoint: endpoint,
                direction: configuration.direction,
                audioSource: configuration.audioSource,
                credentials: configuration.credentials,
                asrContextTerms: configuration.asrContextTerms
            )
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
            try await client.start(
                direction: configuration.direction,
                asrContextTerms: configuration.asrContextTerms
            )
            try ensureStarting(token)
            try throwIfBackendStartRejected()

            startupStage = .audioCapture
            let generation = queue.reset()
            queueGeneration = generation
            audioDrainTask = makeAudioDrainTask(
                generation: generation,
                token: token
            )
            let failureGate = CaptureFailureGate()
            captureFailureGate = failureGate
            captureAttempted = true
            captureWasStarted = true
            try await capture.start(
                source: configuration.audioSource,
                onFrame: { [queue] frame in
                    queue.offer(frame, generation: generation)
                },
                onFailure: { [weak self, queue] failure in
                    if failure == .pipelineOverloaded {
                        queue.signalOverflow(generation: generation)
                        return
                    }
                    if failureGate.claim(failure) == .runtime {
                        Task {
                            await self?.beginRuntimeCaptureFailure(
                                failure,
                                generation: generation,
                                token: token
                            )
                        }
                    }
                }
            )
            try ensureStarting(token)
            if let failure = failureGate.startupFailure {
                throw failure
            }
            try throwIfBackendStartRejected()

            await diagnostics.record(.sessionStart(
                host: endpoint.webSocketURL.host ?? "unknown",
                port: Self.effectivePort(for: endpoint),
                direction: configuration.direction,
                username: configuration.credentials?.username,
                hotwordCount: configuration.asrContextTerms.count,
                hotwordCharacters: AsrContextTermsParser.countJoinedCharacters(
                    configuration.asrContextTerms
                ),
                deviceID: configuration.audioSource.id,
                deviceName: configuration.audioSource.name
            ))
            await diagnostics.record(.capture(category: "started"))
            try ensureStarting(token)
            if let failure = failureGate.commitRunning() {
                throw failure
            }
            transition(to: .running)
            publish(.status(runningStatus))
        } catch {
            let interruptedByStop = state == .finishing || token != sessionToken
            await rollbackStart(
                connected: connected,
                captureAttempted: captureAttempted
            )
            if interruptedByStop {
                throw CancellationError()
            }

            await diagnostics.record(.failure(category: startupStage.category))
            publish(.failure(Self.failureMessage(for: error)))
            clearSessionResources()
            transition(to: .stopped)
            throw error
        }
    }

    private func performStop(
        token: UInt64,
        startupToWait: Task<Void, Error>?,
        stoppedDuringStart: Bool
    ) async {
        if stoppedDuringStart {
            _ = try? await startupToWait?.value
            clearSessionResources()
            stopTask = nil
            transition(to: .stopped)
            return
        }

        if captureWasStarted {
            captureWasStarted = false
            await capture.stop()
        }
        await stopAudioPipeline()

        let connected = await client.isConnected
        if connected && !backendFaulted {
            let (stream, continuation) = AsyncStream.makeStream(
                of: Void.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            finalSignalToken = token
            finalSignalContinuation = continuation
            do {
                try await client.finish()
                let result = await waitForFinalOrTimeout(
                    stream: stream,
                    signalContinuation: continuation
                )
                if result == .timeout {
                    publish(.status("Final wait timeout"))
                }
            } catch {
                await diagnostics.record(.failure(category: "finish"))
                publish(.status("Finish failed"))
            }
            continuation.finish()
            if finalSignalToken == token {
                finalSignalContinuation = nil
                finalSignalToken = nil
            }
        }

        if sessionToken == token {
            sessionToken &+= 1
        }
        await cancelClientOutputTask()
        await client.disconnect()
        clearSessionResources()
        stopTask = nil
        transition(to: .stopped)
    }

    private func beginRuntimeCaptureFailure(
        _ failure: AudioCaptureFailure,
        generation: UInt64,
        token: UInt64
    ) async {
        guard state == .running,
              token == sessionToken,
              generation == queueGeneration,
              stopTask == nil else {
            return
        }

        transition(to: .finishing)
        captureFailureGate?.deactivate()
        sessionToken &+= 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFatalCaptureStop(failure)
        }
        stopTask = task
    }

    private func performFatalCaptureStop(
        _ failure: AudioCaptureFailure
    ) async {
        await diagnostics.record(.failure(category: "capture_runtime"))
        publish(.failure(Self.failureMessage(for: failure)))
        if captureWasStarted {
            captureWasStarted = false
            await capture.stop()
        }
        await stopAudioPipeline()
        await cancelClientOutputTask()
        await client.disconnect()
        clearSessionResources()
        stopTask = nil
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
        guard audioWorkIsCurrent(generation: generation, token: token) else {
            return
        }

        switch event {
        case let .frame(frame):
            if let previous = lastAudioCallbackTimestamp,
               frame.callbackTimestamp.duration(since: previous)
                    >= policy.callbackGapThreshold {
                backendFaulted = true
                publish(.status("Audio idle reconnect"))
            }
            lastAudioCallbackTimestamp = frame.callbackTimestamp
            await send(frame, generation: generation, token: token)

        case .overflow:
            backendFaulted = true
            if !audioOverloadReported {
                audioOverloadReported = true
                publish(.status("Audio pipeline overloaded"))
                await diagnostics.record(.failure(category: "audio_overload"))
            }
        }
    }

    private func send(
        _ frame: CapturedAudioFrame,
        generation: UInt64,
        token: UInt64
    ) async {
        do {
            try await ensureBackendSession(
                generation: generation,
                token: token
            )
        } catch {
            await recordAudioFailureIfCurrent(
                "audio_reconnect",
                generation: generation,
                token: token
            )
            return
        }

        do {
            try ensureAudioWorkCurrent(generation: generation, token: token)
            try await client.sendAudioFrame(frame.pcm16LE)
        } catch {
            guard audioWorkIsCurrent(generation: generation, token: token) else {
                return
            }
            backendFaulted = true
            do {
                try await ensureBackendSession(
                    generation: generation,
                    token: token
                )
                try ensureAudioWorkCurrent(generation: generation, token: token)
                try await client.sendAudioFrame(frame.pcm16LE)
            } catch {
                backendFaulted = true
                await recordAudioFailureIfCurrent(
                    "audio_send",
                    generation: generation,
                    token: token
                )
                return
            }
        }

        guard audioWorkIsCurrent(generation: generation, token: token) else {
            return
        }
        sentFrameCount &+= 1
        if sentFrameCount <= 3 || sentFrameCount.isMultiple(of: 50) {
            await diagnostics.record(.audio(
                frameCount: sentFrameCount,
                byteCount: frame.pcm16LE.count
            ))
        }
    }

    private func ensureBackendSession(
        generation: UInt64,
        token: UInt64
    ) async throws {
        let connected = await client.isConnected
        try ensureAudioWorkCurrent(generation: generation, token: token)
        guard backendFaulted || !connected else { return }

        if let reconnectTask {
            try await reconnectTask.value
            try ensureAudioWorkCurrent(generation: generation, token: token)
            return
        }
        guard let configuration = activeConfiguration else {
            throw CancellationError()
        }

        publish(.status("Reconnecting"))
        runningStatus = "Running"
        resetBackendSessionFault()
        let task = Task { [client] in
            try await client.connect(
                to: configuration.endpoint,
                credentials: configuration.credentials
            )
            try await client.start(
                direction: configuration.direction,
                asrContextTerms: configuration.asrContextTerms
            )
        }
        reconnectTask = task
        do {
            try await task.value
            try ensureAudioWorkCurrent(generation: generation, token: token)
            try throwIfBackendStartRejected()
            reconnectTask = nil
            backendFaulted = false
            backendSessionErrorMessage = nil
            audioOverloadReported = false
            publish(.status(runningStatus))
        } catch {
            reconnectTask = nil
            if audioWorkIsCurrent(generation: generation, token: token) {
                backendFaulted = true
            }
            throw error
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
                let message = Self.conciseBackendMessage(event.message)
                if state != .finishing {
                    backendFaulted = true
                    backendSessionErrorMessage = message
                        ?? "Backend rejected the session start."
                    backendStartRejectedMessage = backendSessionErrorMessage
                }
                if let message {
                    publish(.status(message))
                }
            }
            if event.type == .started {
                runningStatus = formatRunningStatus(event)
                publish(.status(runningStatus))
            }
            if event.type == .final || event.type == .error {
                resolveFinalSignal(token: token)
            }

        case let .connection(connection):
            switch connection {
            case .connected:
                await diagnostics.record(.connection(category: "connected"))
                publish(.status("Connected"))
            case .disconnected:
                if state != .finishing {
                    backendFaulted = true
                    backendSessionErrorMessage = "Disconnected"
                }
                await diagnostics.record(.connection(category: "disconnected"))
                publish(.status("Disconnected"))
            case .parseError:
                await diagnostics.record(.failure(category: "parse_error"))
                publish(.status("Receive parse error"))
            case .receiveError:
                if state != .finishing {
                    backendFaulted = true
                    backendSessionErrorMessage = "Receive error"
                }
                await diagnostics.record(.failure(category: "receive_error"))
                publish(.status("Receive error"))
            }
        }
    }

    private func recordBackendDiagnostic(_ event: VoxBridgeEvent) async {
        guard diagnostics.isEnabled else { return }
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
            asrContextActive: event.asrContextActive,
            asrContextTermCount: event.asrContextTermCount,
            asrContextCharacters: event.asrContextCharacters,
            messageLength: event.message?.utf16.count ?? 0,
            stability: event.stability,
            transcript: transcript,
            translation: translation
        ))
    }

    private func rollbackStart(
        connected: Bool,
        captureAttempted: Bool
    ) async {
        captureFailureGate?.deactivate()
        if captureAttempted && captureWasStarted {
            captureWasStarted = false
            await capture.stop()
        }
        await stopAudioPipeline()
        await cancelClientOutputTask()
        let clientIsConnected = await client.isConnected
        if connected || clientIsConnected {
            await client.disconnect()
        }
    }

    private func stopAudioPipeline() async {
        if let queueGeneration {
            queue.finish(generation: queueGeneration)
        }
        let drain = audioDrainTask
        audioDrainTask = nil
        drain?.cancel()
        let reconnect = reconnectTask
        reconnectTask = nil
        reconnect?.cancel()
        if let reconnect { _ = try? await reconnect.value }
        if let drain { await drain.value }
        queueGeneration = nil
    }

    private func cancelClientOutputTask() async {
        let task = clientOutputTask
        clientOutputTask = nil
        task?.cancel()
        if let task { await task.value }
    }

    private func waitForFinalOrTimeout(
        stream: AsyncStream<Void>,
        signalContinuation: AsyncStream<Void>.Continuation
    ) async -> FinalWaitResult {
        let (results, resultContinuation) = AsyncStream.makeStream(
            of: FinalWaitResult.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let finalTask = Task {
            var iterator = stream.makeAsyncIterator()
            if await iterator.next() != nil {
                resultContinuation.yield(.backend)
            }
        }
        let timeout = policy.finalWaitTimeout
        let timeoutTask = Task { [clock] in
            do {
                try await clock.sleep(for: timeout)
                resultContinuation.yield(.timeout)
            } catch {
                resultContinuation.yield(.cancelled)
            }
        }
        var iterator = results.makeAsyncIterator()
        let result = await iterator.next() ?? .cancelled
        finalTask.cancel()
        timeoutTask.cancel()
        signalContinuation.finish()
        resultContinuation.finish()
        await finalTask.value
        await timeoutTask.value
        return result
    }

    private func resolveFinalSignal(token: UInt64) {
        guard finalSignalToken == token,
              let continuation = finalSignalContinuation else { return }
        finalSignalContinuation = nil
        finalSignalToken = nil
        continuation.yield(())
        continuation.finish()
    }

    private func recordAudioFailureIfCurrent(
        _ category: String,
        generation: UInt64,
        token: UInt64
    ) async {
        guard audioWorkIsCurrent(generation: generation, token: token) else {
            return
        }
        await diagnostics.record(.failure(category: category))
    }

    private func audioWorkIsCurrent(
        generation: UInt64,
        token: UInt64
    ) -> Bool {
        token == sessionToken
            && generation == queueGeneration
            && (state == .starting || state == .running)
    }

    private func ensureAudioWorkCurrent(
        generation: UInt64,
        token: UInt64
    ) throws {
        guard audioWorkIsCurrent(generation: generation, token: token) else {
            throw CancellationError()
        }
    }

    private func ensureStarting(_ token: UInt64) throws {
        guard token == sessionToken, state == .starting else {
            throw CancellationError()
        }
    }

    private func completeStartup(token: UInt64) {
        guard token == sessionToken || state == .finishing else { return }
        startupTask = nil
    }

    private func clearSessionResources() {
        captureFailureGate?.deactivate()
        captureFailureGate = nil
        activeConfiguration = nil
        resetBackendSessionFault()
        runningStatus = "Running"
        audioOverloadReported = false
        sentFrameCount = 0
        lastAudioCallbackTimestamp = nil
        captureWasStarted = false
        finalSignalContinuation?.finish()
        finalSignalContinuation = nil
        finalSignalToken = nil
    }

    private func transition(to nextState: SubtitleSessionState) {
        state = nextState
        publish(.state(nextState))
    }

    private func publish(_ output: SubtitleSessionOutput) {
        outputContinuation?.yield(output)
    }

    private func removeOutputSubscription(_ id: UUID) {
        guard outputSubscriptionID == id else { return }
        outputSubscriptionID = nil
        outputContinuation = nil
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

    private func formatRunningStatus(_ event: VoxBridgeEvent) -> String {
        let requestedCount = activeConfiguration?.asrContextTerms.count ?? 0
        guard requestedCount > 0 else { return "Running" }
        guard event.asrContextActive != nil
                || event.asrContextTermCount != nil else {
            return "Running · Hotwords not confirmed"
        }
        let activeCount = event.asrContextTermCount
            ?? (event.asrContextActive == true ? requestedCount : 0)
        return "Running · Hotwords: \(activeCount)"
    }

    private func throwIfBackendStartRejected() throws {
        guard let backendStartRejectedMessage else { return }
        throw SubtitleSessionError.backendRejected(
            backendStartRejectedMessage
        )
    }

    private func resetBackendSessionFault() {
        backendFaulted = false
        backendSessionErrorMessage = nil
        backendStartRejectedMessage = nil
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
        let normalized = value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(normalized.prefix(256))
    }

    private static func failureMessage(for error: Error) -> String {
        switch error {
        case let error as SubtitleSessionError:
            error.localizedDescription
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

    private enum FinalWaitResult: Sendable {
        case backend
        case timeout
        case cancelled
    }
}

private final class CaptureFailureGate: @unchecked Sendable {
    enum Disposition: Equatable {
        case startup
        case runtime
        case ignored
    }

    private enum Phase {
        case starting
        case running
        case inactive
    }

    private let lock = NSLock()
    private var phase: Phase = .starting
    private var failure: AudioCaptureFailure?

    var startupFailure: AudioCaptureFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func claim(_ failure: AudioCaptureFailure) -> Disposition {
        lock.lock()
        defer { lock.unlock() }
        guard self.failure == nil else { return .ignored }
        switch phase {
        case .starting:
            self.failure = failure
            return .startup
        case .running:
            self.failure = failure
            return .runtime
        case .inactive:
            return .ignored
        }
    }

    func commitRunning() -> AudioCaptureFailure? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return failure }
        guard phase == .starting else { return nil }
        phase = .running
        return nil
    }

    func deactivate() {
        lock.lock()
        phase = .inactive
        lock.unlock()
    }
}
