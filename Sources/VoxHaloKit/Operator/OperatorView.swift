import SwiftUI

public struct OperatorView: View {
    public static let controlIdentifiers: Set<String> = [
        "operator.root",
        "operator.backend",
        "operator.username",
        "operator.password",
        "operator.direction",
        "operator.audioSource",
        "operator.display",
        "operator.target.height",
        "operator.target.font",
        "operator.target.offset",
        "operator.target.color",
        "operator.reference.height",
        "operator.reference.font",
        "operator.reference.offset",
        "operator.reference.color",
        "operator.start",
        "operator.stop",
        "operator.status",
    ]

    public static let targetAreaHeightRange: ClosedRange<CGFloat> = 120 ... 640
    public static let targetFontSizeRange: ClosedRange<CGFloat> = 18 ... 56
    public static let targetTopOffsetRange: ClosedRange<CGFloat> = 0 ... 900
    public static let referenceAreaHeightRange: ClosedRange<CGFloat> = 48 ... 360
    public static let referenceFontSizeRange: ClosedRange<CGFloat> = 16 ... 42
    public static let referenceBottomOffsetRange: ClosedRange<CGFloat> = 0 ... 900

    @ObservedObject private var model: OperatorModel

    public init(model: OperatorModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sessionSection
                overlaySection
                layoutSection(
                    title: "Translation",
                    height: $model.layout.targetAreaHeight,
                    heightRange: Self.targetAreaHeightRange,
                    heightIdentifier: "operator.target.height",
                    font: $model.layout.targetFontSize,
                    fontRange: Self.targetFontSizeRange,
                    fontIdentifier: "operator.target.font",
                    offsetTitle: "Top offset",
                    offset: $model.layout.targetTopOffset,
                    offsetRange: Self.targetTopOffsetRange,
                    offsetIdentifier: "operator.target.offset",
                    color: $model.layout.targetColor,
                    colorIdentifier: "operator.target.color"
                )
                layoutSection(
                    title: "Recognition",
                    height: $model.layout.referenceAreaHeight,
                    heightRange: Self.referenceAreaHeightRange,
                    heightIdentifier: "operator.reference.height",
                    font: $model.layout.referenceFontSize,
                    fontRange: Self.referenceFontSizeRange,
                    fontIdentifier: "operator.reference.font",
                    offsetTitle: "Bottom offset",
                    offset: $model.layout.referenceBottomOffset,
                    offsetRange: Self.referenceBottomOffsetRange,
                    offsetIdentifier: "operator.reference.offset",
                    color: $model.layout.referenceColor,
                    colorIdentifier: "operator.reference.color"
                )
                actionSection
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 700)
        .accessibilityIdentifier("operator.root")
    }

    private var sessionSection: some View {
        GroupBox("Session") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    fieldLabel("VoxBridge endpoint")
                    TextField("wss://host/ws", text: $model.backendURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEditBackend)
                        .accessibilityIdentifier("operator.backend")
                }
                if let warning = model.endpointWarning {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                GridRow {
                    fieldLabel("Username")
                    TextField("admin", text: $model.username)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEditBackend)
                        .accessibilityIdentifier("operator.username")
                }
                GridRow {
                    fieldLabel("Password")
                    SecureField("Stored in memory only", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEditBackend)
                        .accessibilityIdentifier("operator.password")
                }
                GridRow {
                    fieldLabel("Direction")
                    Picker("Direction", selection: $model.direction) {
                        ForEach(model.directions, id: \.rawValue) { direction in
                            Text(model.directionLabel(direction)).tag(direction)
                        }
                    }
                    .labelsHidden()
                    .disabled(!model.canEditDirection)
                    .accessibilityIdentifier("operator.direction")
                }
                GridRow {
                    fieldLabel("Audio source")
                    Picker("Audio source", selection: $model.selectedAudioSourceID) {
                        ForEach(model.audioSources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(!model.canEditAudioSource)
                    .accessibilityIdentifier("operator.audioSource")
                }
            }
            .padding(8)
        }
    }

    private var overlaySection: some View {
        GroupBox("Overlay") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    fieldLabel("Display")
                    Picker("Display", selection: $model.selectedDisplayUUID) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(Optional(display.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("operator.display")
                }
                GridRow {
                    fieldLabel("Mode")
                    Text("Transparent click-through overlay")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private func layoutSection(
        title: String,
        height: Binding<CGFloat>,
        heightRange: ClosedRange<CGFloat>,
        heightIdentifier: String,
        font: Binding<CGFloat>,
        fontRange: ClosedRange<CGFloat>,
        fontIdentifier: String,
        offsetTitle: String,
        offset: Binding<CGFloat>,
        offsetRange: ClosedRange<CGFloat>,
        offsetIdentifier: String,
        color: Binding<String>,
        colorIdentifier: String
    ) -> some View {
        GroupBox("\(title) subtitle layout") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Area height",
                    value: height,
                    range: heightRange,
                    identifier: heightIdentifier
                )
                sliderRow(
                    title: "Font size",
                    value: font,
                    range: fontRange,
                    identifier: fontIdentifier
                )
                sliderRow(
                    title: offsetTitle,
                    value: offset,
                    range: offsetRange,
                    identifier: offsetIdentifier
                )
                HStack(spacing: 12) {
                    fieldLabel("Color")
                    Picker("Color", selection: color) {
                        ForEach(model.colorChoices) { choice in
                            Text(choice.name).tag(choice.hex)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier(colorIdentifier)
                }
            }
            .padding(8)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        identifier: String
    ) -> some View {
        HStack(spacing: 12) {
            fieldLabel(title)
            Slider(value: value, in: range, step: 1)
            TextField(
                title,
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = CGFloat($0) }
                ),
                format: .number.precision(.fractionLength(0))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
        }
        .accessibilityIdentifier(identifier)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let destination = model.permissionSettingsDestination {
                PermissionSettingsLink(destination: destination)
            }
            HStack(spacing: 10) {
                Button("Start") {
                    Task { await model.start() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
                .accessibilityIdentifier("operator.start")

                Button("Stop") {
                    Task { await model.stop() }
                }
                .disabled(!model.canStop)
                .accessibilityIdentifier("operator.stop")

                Spacer()
                Text(model.status)
                    .foregroundStyle(
                        model.errorMessage == nil ? Color.secondary : Color.red
                    )
                    .lineLimit(2)
                    .accessibilityIdentifier("operator.status")
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .frame(width: 128, alignment: .leading)
    }
}
