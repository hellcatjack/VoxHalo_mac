import Foundation

@MainActor
public final class AppEnvironment {
    public let operatorModel: OperatorModel
    public let overlayController: any SubtitleOverlayControlling

    private let additionalCleanup: @MainActor @Sendable () async -> Void
    private var didFinishLaunching = false
    private var shutdownTask: Task<Void, Never>?

    public init(
        operatorModel: OperatorModel,
        overlay: any SubtitleOverlayControlling,
        additionalCleanup: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.operatorModel = operatorModel
        overlayController = overlay
        self.additionalCleanup = additionalCleanup
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppEnvironment {
        let settingsStore = SettingsStore()
        let diagnostics: any DiagnosticsLogging
        do {
            diagnostics = try DiagnosticsLogger(environment: environment)
        } catch {
            diagnostics = DisabledDiagnosticsLogger()
        }

        let permissionProvider = AudioPermissionProvider()
        let captureDeviceCatalog = CoreAudioDeviceCatalog()
        let operatorAudioCatalog = CoreAudioDeviceCatalog()
        let systemAudioCapture = SystemAudioTapCapture()
        let hardwareInputCapture = HardwareInputCapture(
            deviceCatalog: captureDeviceCatalog,
            permissionProvider: permissionProvider
        )
        let captureService = CoreAudioCaptureService(
            systemAudioCapture: systemAudioCapture,
            hardwareInputCapture: hardwareInputCapture
        )
        let client = VoxBridgeClient()
        let coordinator = SubtitleSessionCoordinator(
            client: client,
            capture: captureService,
            sourceValidator: operatorAudioCatalog,
            permissionProvider: permissionProvider,
            queue: BoundedAudioFrameQueue(),
            store: SubtitleStateStore(direction: .chineseToEnglish),
            diagnostics: diagnostics
        )

        // The picker and the always-on overlay each own an independent observer.
        // NSScreen and Core Audio callbacks are process-wide underneath these thin
        // catalogs, while separate instances prevent one consumer replacing the
        // other's single callback slot.
        let operatorDisplayCatalog = DisplayCatalog()
        let overlayDisplayCatalog = DisplayCatalog()
        let overlayController = SubtitleOverlayController(
            displayCatalog: overlayDisplayCatalog
        )
        let model = OperatorModel(
            settingsStore: settingsStore,
            sessionCoordinator: coordinator,
            audioCatalog: operatorAudioCatalog,
            displayCatalog: operatorDisplayCatalog,
            overlay: overlayController,
            environment: environment
        )

        return AppEnvironment(
            operatorModel: model,
            overlay: overlayController,
            additionalCleanup: {
                await captureService.stop()
                captureDeviceCatalog.stopObserving()
            }
        )
    }

    public func applicationDidFinishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        overlayController.apply(layout: operatorModel.layout)
        overlayController.showEmpty(on: operatorModel.selectedDisplayUUID)
    }

    public func shutDown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        let operatorModel = operatorModel
        let overlay = overlayController
        let additionalCleanup = additionalCleanup
        let task = Task { @MainActor in
            await operatorModel.shutDown()
            await additionalCleanup()
            overlay.close()
        }
        shutdownTask = task
        await task.value
    }
}

private struct DisabledDiagnosticsLogger: DiagnosticsLogging, Sendable {
    let isEnabled = false

    func record(_ event: DiagnosticEvent) async {}
}
