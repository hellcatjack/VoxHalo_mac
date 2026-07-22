import AppKit

@MainActor
public final class SubtitleOverlayController {
    public let panel: SubtitleOverlayPanel
    public let overlayView: SubtitleOverlayView
    public private(set) var activeDisplay: DisplayDescriptor?

    private let displayCatalog: any DisplayCataloging
    private var selectedDisplayUUID: String?
    private var layout = SubtitleLayoutSettings.defaults
    private var isObserving = false

    public init(
        displayCatalog: any DisplayCataloging = DisplayCatalog(),
        panel: SubtitleOverlayPanel = SubtitleOverlayPanel(),
        overlayView: SubtitleOverlayView = SubtitleOverlayView(frame: .zero)
    ) {
        self.displayCatalog = displayCatalog
        self.panel = panel
        self.overlayView = overlayView
        overlayView.autoresizingMask = [.width, .height]
        panel.contentView = overlayView
    }

    public func showEmpty(on displayUUID: String?) {
        selectedDisplayUUID = displayUUID
        overlayView.apply(model: .empty(for: .chineseToEnglish))
        place(on: displayCatalog.selectedDisplay(savedUUID: displayUUID))
        if !isObserving {
            displayCatalog.startObserving { [weak self] displays in
                self?.handleDisplayChange(displays)
            }
            isObserving = true
        }
        panel.orderFrontRegardless()
    }

    public func apply(model: SubtitleDisplayModel) {
        overlayView.apply(model: model)
    }

    public func apply(layout: SubtitleLayoutSettings) {
        self.layout = layout.normalized()
        if let activeDisplay {
            overlayView.apply(layout: self.layout, display: activeDisplay)
            overlayView.layoutSubtreeIfNeeded()
        } else {
            overlayView.apply(layout: self.layout)
        }
    }

    public func selectDisplay(uuid: String?) {
        selectedDisplayUUID = uuid
        place(on: displayCatalog.selectedDisplay(savedUUID: uuid))
    }

    public func close() {
        if isObserving {
            displayCatalog.stopObserving()
            isObserving = false
        }
        activeDisplay = nil
        panel.orderOut(nil)
    }

    private func handleDisplayChange(_ displays: [DisplayDescriptor]) {
        let display: DisplayDescriptor?
        if let selectedDisplayUUID,
           let selected = displays.first(where: { $0.id == selectedDisplayUUID }) {
            display = selected
        } else {
            display = displays.first(where: \.isMain) ?? displays.first
        }
        guard let display else {
            activeDisplay = nil
            panel.orderOut(nil)
            return
        }
        place(on: display)
        panel.orderFrontRegardless()
    }

    private func place(on display: DisplayDescriptor) {
        activeDisplay = display
        panel.setFrame(display.frame, display: true)
        overlayView.frame = CGRect(origin: .zero, size: display.frame.size)
        overlayView.apply(layout: layout, display: display)
        overlayView.layoutSubtreeIfNeeded()
    }
}
