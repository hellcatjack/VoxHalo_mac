import Combine
import Foundation

@MainActor
public final class OperatorModel: ObservableObject {
    @Published public var backendURL: String {
        didSet { persistIfReady() }
    }

    @Published public var username: String {
        didSet { persistIfReady() }
    }

    @Published public var password: String = ""

    @Published public var hotwordsText: String {
        didSet { persistIfReady() }
    }

    @Published public var direction: TranslationDirection {
        didSet { persistIfReady() }
    }

    @Published public var selectedAudioSourceID: String {
        didSet { persistIfReady() }
    }

    @Published public var selectedDisplayUUID: String? {
        didSet {
            guard isReady else { return }
            overlay.selectDisplay(uuid: selectedDisplayUUID)
            persistSettings()
        }
    }

    @Published public var layout: SubtitleLayoutSettings {
        didSet {
            guard isReady else { return }
            let normalized = layout.normalized()
            if layout != normalized {
                layout = normalized
            }
            overlay.apply(layout: normalized)
            persistSettings()
        }
    }

    @Published public private(set) var audioSources: [AudioSource]
    @Published public private(set) var displays: [DisplayDescriptor]
    @Published public private(set) var state: SubtitleSessionState = .stopped
    @Published public private(set) var status: String = "Stopped"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var permissionSettingsDestination:
        PermissionSettingsDestination?

    public let directions = TranslationDirection.allCases
    public let colorChoices = SubtitleColorChoice.all
    public let usesTransparentOverlayOnly = true

    private let settingsStore: any AppSettingsStoring
    private let sessionCoordinator: any SubtitleSessionCoordinating
    private let audioCatalog: any AudioDeviceCataloging
    private let displayCatalog: any DisplayCataloging
    private let overlay: any SubtitleOverlayControlling
    private let updatePump: SubtitleUIUpdatePump

    private var settingsTemplate: AppSettings
    private var sessionOutputTask: Task<Void, Never>?
    private var isReady = false
    private var isAudioObserving = false
    private var isDisplayObserving = false
    private var isShutDown = false

    public init(
        settingsStore: any AppSettingsStoring,
        sessionCoordinator: any SubtitleSessionCoordinating,
        audioCatalog: any AudioDeviceCataloging,
        displayCatalog: any DisplayCataloging,
        overlay: any SubtitleOverlayControlling,
        updateScheduler: (any MainActorScheduling)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.settingsStore = settingsStore
        self.sessionCoordinator = sessionCoordinator
        self.audioCatalog = audioCatalog
        self.displayCatalog = displayCatalog
        self.overlay = overlay

        let loadedSettings: AppSettings
        let settingsLoadFailed: Bool
        do {
            loadedSettings = try settingsStore.load()
            settingsLoadFailed = false
        } catch {
            loadedSettings = .defaults
            settingsLoadFailed = true
        }
        settingsTemplate = loadedSettings

        backendURL = loadedSettings.backendURL.absoluteString
        username = Self.nonBlank(environment["VOXBRIDGE_AUTH_USERNAME"])
            ?? loadedSettings.authUsername
        password = environment["VOXBRIDGE_AUTH_PASSWORD"] ?? ""
        hotwordsText = loadedSettings.asrContextTermsText
        direction = loadedSettings.direction
        layout = SubtitleLayoutSettings(settings: loadedSettings).normalized()

        let initialSources: [AudioSource]
        do {
            initialSources = try audioCatalog.sources()
        } catch {
            initialSources = [.systemAudio]
        }
        audioSources = initialSources
        selectedAudioSourceID = AudioSourceSelection.preferred(
            from: initialSources,
            savedID: loadedSettings.preferredAudioDeviceID
        )?.id ?? ""

        let initialDisplays = displayCatalog.displays()
        displays = initialDisplays
        selectedDisplayUUID = Self.preferredDisplay(
            from: initialDisplays,
            savedUUID: loadedSettings.preferredDisplayUUID
        )?.id

        let scheduler = updateScheduler ?? ContinuousMainActorScheduler()
        updatePump = SubtitleUIUpdatePump(scheduler: scheduler) { [weak overlay] model in
            overlay?.apply(model: model)
        }

        if settingsLoadFailed {
            let message = "Settings could not be loaded; using defaults."
            status = message
            errorMessage = message
        }

        isReady = true
        overlay.apply(layout: layout)
        overlay.selectDisplay(uuid: selectedDisplayUUID)
        startAudioObservation()
        startDisplayObservation()
        startSessionOutputTask()

        if loadedSettings.preferredAudioDeviceID != nil,
           loadedSettings.preferredAudioDeviceID != selectedAudioSourceID {
            persistSettings()
        }
    }

    deinit {
        sessionOutputTask?.cancel()
    }

    public var canEditBackend: Bool { state == .stopped }
    public var canEditDirection: Bool { state == .stopped }
    public var canEditAudioSource: Bool { state == .stopped }
    public var canEditHotwords: Bool { state == .stopped }
    public var canEditDisplayAndLayout: Bool { true }

    public var endpointIsInsecure: Bool {
        backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("ws://")
    }

    public var endpointWarning: String? {
        endpointIsInsecure ? "ws:// is not encrypted" : nil
    }

    public var canStart: Bool {
        state == .stopped
            && validatedEndpoint() != nil
            && audioSources.contains(where: { $0.id == selectedAudioSourceID })
    }

    public var canStop: Bool {
        state == .starting || state == .running
    }

    public func directionLabel(_ value: TranslationDirection) -> String {
        switch value {
        case .chineseToEnglish:
            "Chinese → English"
        case .englishToChinese:
            "English → Chinese"
        }
    }

    public func start() async {
        guard state == .stopped else { return }
        refreshAudioSources()

        guard let endpoint = validatedEndpoint() else {
            setFailure("Enter a valid ws:// or wss:// VoxBridge endpoint.")
            return
        }
        guard let source = audioSources.first(where: {
            $0.id == selectedAudioSourceID
        }) else {
            setFailure("Select an available audio source.")
            return
        }
        let asrContextTerms: [String]
        do {
            asrContextTerms = try AsrContextTermsParser.parse(hotwordsText)
        } catch {
            setFailure(error.localizedDescription)
            return
        }

        errorMessage = nil
        permissionSettingsDestination = nil
        state = .starting
        status = "Starting…"
        persistSettings()

        let credentials = VoxBridgeAuthCredentials.make(
            username: username,
            password: password
        )
        let configuration = SubtitleSessionConfiguration(
            endpoint: endpoint,
            direction: direction,
            audioSource: source,
            credentials: credentials,
            asrContextTerms: asrContextTerms
        )

        do {
            try await sessionCoordinator.start(configuration)
            if state == .starting {
                state = .running
                status = "Running"
            }
        } catch is CancellationError {
            if state != .finishing {
                state = .stopped
                setFailure("Subtitle startup was cancelled.")
            }
        } catch {
            state = .stopped
            handleStartFailure(error)
            refreshAudioSources()
            restartAudioObservation()
        }
    }

    public func stop() async {
        guard canStop else { return }
        state = .finishing
        if errorMessage == nil {
            status = "Stopping…"
        }
        await sessionCoordinator.stop()
        state = .stopped
        if errorMessage == nil {
            status = "Stopped"
        }
        updatePump.cancel()
        refreshAudioSources()
        restartAudioObservation()
    }

    public func shutDown() async {
        guard !isShutDown else { return }
        isShutDown = true
        updatePump.cancel()
        sessionOutputTask?.cancel()
        sessionOutputTask = nil
        await sessionCoordinator.stop()
        if isAudioObserving {
            audioCatalog.stopObserving()
            isAudioObserving = false
        }
        if isDisplayObserving {
            displayCatalog.stopObserving()
            isDisplayObserving = false
        }
        state = .stopped
    }

    private func persistIfReady() {
        guard isReady else { return }
        persistSettings()
    }

    private func persistSettings() {
        let endpoint = URL(string: backendURL).flatMap { url in
            try? VoxBridgeEndpoint(validating: url).webSocketURL
        } ?? settingsTemplate.backendURL
        let settings = AppSettings(
            backendURL: endpoint,
            direction: direction,
            preferredAudioDeviceID: Self.nonBlank(selectedAudioSourceID),
            preferredDisplayUUID: Self.nonBlank(selectedDisplayUUID),
            targetAreaHeight: Double(layout.targetAreaHeight),
            targetFontSize: Double(layout.targetFontSize),
            targetTopOffset: Double(layout.targetTopOffset),
            targetColor: layout.targetColor,
            authUsername: Self.nonBlank(username) ?? "admin",
            referenceAreaHeight: Double(layout.referenceAreaHeight),
            referenceFontSize: Double(layout.referenceFontSize),
            referenceBottomOffset: Double(layout.referenceBottomOffset),
            referenceColor: layout.referenceColor,
            asrContextTermsText: hotwordsText,
            unknownFields: settingsTemplate.unknownFields
        ).normalized()
        do {
            try settingsStore.save(settings)
            settingsTemplate = settings
        } catch {
            setFailure("Settings could not be saved.")
        }
    }

    private func validatedEndpoint() -> VoxBridgeEndpoint? {
        let value = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else { return nil }
        return try? VoxBridgeEndpoint(validating: url)
    }

    private func startSessionOutputTask() {
        let coordinator = sessionCoordinator
        sessionOutputTask = Task { @MainActor [weak self] in
            let stream = await coordinator.outputs()
            for await output in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(output)
            }
        }
    }

    private func handle(_ output: SubtitleSessionOutput) {
        switch output {
        case let .state(value):
            if state == .stopped, value != .stopped {
                return
            }
            state = value
            switch value {
            case .stopped:
                if errorMessage == nil { status = "Stopped" }
                refreshAudioSources()
                restartAudioObservation()
            case .starting:
                status = "Starting…"
            case .running:
                status = "Running"
            case .finishing:
                if errorMessage == nil { status = "Stopping…" }
            }
        case let .subtitle(model):
            updatePump.post(model)
        case let .status(message):
            status = Self.concise(message)
        case let .failure(message):
            let message = Self.concise(message)
            if message.localizedCaseInsensitiveContains("authentication") {
                setFailure("Authentication failed. Please check username/password.")
            } else {
                setFailure(message)
                inferPermissionDestination(from: message)
            }
        }
    }

    private func startAudioObservation() {
        guard !isAudioObserving else { return }
        do {
            try audioCatalog.startObserving { [weak self] sources in
                Task { @MainActor [weak self] in
                    self?.handleAudioSources(sources)
                }
            }
            isAudioObserving = true
        } catch {
            if errorMessage == nil {
                setFailure("Audio sources could not be monitored.")
            }
        }
    }

    private func restartAudioObservation() {
        if isAudioObserving {
            audioCatalog.stopObserving()
            isAudioObserving = false
        }
        guard !isShutDown else { return }
        startAudioObservation()
    }

    private func refreshAudioSources() {
        guard let sources = try? audioCatalog.sources() else { return }
        handleAudioSources(sources)
    }

    private func handleAudioSources(_ sources: [AudioSource]) {
        audioSources = sources
        guard !sources.contains(where: { $0.id == selectedAudioSourceID }) else {
            return
        }

        if state == .starting || state == .running {
            let message = "The selected audio source was disconnected."
            setFailure(message)
            Task { @MainActor [weak self] in
                await self?.stop()
            }
            return
        }

        selectedAudioSourceID = AudioSourceSelection.preferred(
            from: sources,
            savedID: nil
        )?.id ?? ""
    }

    private func startDisplayObservation() {
        guard !isDisplayObserving else { return }
        displayCatalog.startObserving { [weak self] displays in
            self?.handleDisplays(displays)
        }
        isDisplayObserving = true
    }

    private func handleDisplays(_ displays: [DisplayDescriptor]) {
        self.displays = displays
        guard let selectedDisplayUUID,
              displays.contains(where: { $0.id == selectedDisplayUUID }) else {
            self.selectedDisplayUUID = Self.preferredDisplay(
                from: displays,
                savedUUID: nil
            )?.id
            return
        }
    }

    private func handleStartFailure(_ error: Error) {
        switch error {
        case is VoxBridgeAuthenticationError:
            setFailure("Authentication failed. Please check username/password.")
        case AudioCaptureFailure.microphonePermissionDenied:
            permissionSettingsDestination = .microphone
            setFailure("Microphone access is required for this audio source.")
        case AudioCaptureFailure.systemAudioPermissionDenied:
            permissionSettingsDestination = .systemAudioRecording
            setFailure("System Audio Recording access is required.")
        case let failure as AudioCaptureFailure:
            setFailure(Self.audioFailureMessage(failure))
        case let endpointError as VoxBridgeEndpointError:
            setFailure(endpointError.localizedDescription)
        case let sessionError as SubtitleSessionError:
            switch sessionError {
            case let .backendRejected(message):
                setFailure("Start failed: \(message)")
            case .alreadyActive:
                setFailure(sessionError.localizedDescription)
            }
        default:
            if error.localizedDescription.localizedCaseInsensitiveContains(
                "authentication"
            ) {
                setFailure("Authentication failed. Please check username/password.")
            } else {
                setFailure("Unable to start subtitles.")
            }
        }
    }

    private func inferPermissionDestination(from message: String) {
        if message.localizedCaseInsensitiveContains("microphone") {
            permissionSettingsDestination = .microphone
        } else if message.localizedCaseInsensitiveContains("system audio") {
            permissionSettingsDestination = .systemAudioRecording
        }
    }

    private func setFailure(_ message: String) {
        let message = Self.concise(message)
        errorMessage = message
        status = message
    }

    private static func audioFailureMessage(_ failure: AudioCaptureFailure) -> String {
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
            "Audio pipeline overloaded."
        case .unsupportedFormat:
            "The selected audio format is unsupported."
        case .coreAudio:
            "Audio capture could not be started."
        }
    }

    private static func preferredDisplay(
        from displays: [DisplayDescriptor],
        savedUUID: String?
    ) -> DisplayDescriptor? {
        if let savedUUID,
           let saved = displays.first(where: { $0.id == savedUUID }) {
            return saved
        }
        return displays.first(where: \.isMain) ?? displays.first
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func concise(_ message: String) -> String {
        let oneLine = message.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(oneLine.prefix(256))
    }
}
