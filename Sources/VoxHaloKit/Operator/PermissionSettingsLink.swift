import AppKit
import SwiftUI

public enum PermissionSettingsDestination: Equatable, Sendable {
    case microphone
    case systemAudioRecording

    public var title: String {
        switch self {
        case .microphone:
            "Open Microphone Settings"
        case .systemAudioRecording:
            "Open Screen & System Audio Recording Settings"
        }
    }

    public var settingsURL: URL {
        let pane = switch self {
        case .microphone:
            "Privacy_Microphone"
        case .systemAudioRecording:
            "Privacy_ScreenCapture"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        )!
    }
}

public struct PermissionSettingsLink: View {
    private let destination: PermissionSettingsDestination
    private let opener: @MainActor (URL) -> Void

    public init(
        destination: PermissionSettingsDestination,
        opener: @escaping @MainActor (URL) -> Void = {
            NSWorkspace.shared.open($0)
        }
    ) {
        self.destination = destination
        self.opener = opener
    }

    public var body: some View {
        Button(destination.title) {
            opener(destination.settingsURL)
        }
        .buttonStyle(.link)
    }
}
