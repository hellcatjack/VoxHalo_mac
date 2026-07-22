import AppKit
import CoreGraphics
import Foundation

@MainActor
public protocol DisplayCataloging: AnyObject {
    func displays() -> [DisplayDescriptor]
    func selectedDisplay(savedUUID: String?) -> DisplayDescriptor
    func startObserving(
        _ handler: @escaping @MainActor @Sendable ([DisplayDescriptor]) -> Void
    )
    func stopObserving()
}

@MainActor
public protocol ScreenRepresenting: AnyObject {
    var localizedName: String { get }
    var frame: NSRect { get }
    var backingScaleFactor: CGFloat { get }
    var deviceDescription: [NSDeviceDescriptionKey: Any] { get }
}

@MainActor
public protocol ScreenProviding: AnyObject {
    var screens: [any ScreenRepresenting] { get }
    var mainScreen: (any ScreenRepresenting)? { get }
    func startObservingChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    )
    func stopObservingChanges()
}

extension NSScreen: ScreenRepresenting {}

@MainActor
public final class AppKitScreenProvider: NSObject, ScreenProviding {
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var isObserving = false

    public override init() {
        super.init()
    }

    public var screens: [any ScreenRepresenting] {
        NSScreen.screens
    }

    public var mainScreen: (any ScreenRepresenting)? {
        NSScreen.main
    }

    public func startObservingChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        stopObservingChanges()
        self.onChange = onChange
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        isObserving = true
    }

    public func stopObservingChanges() {
        guard isObserving else {
            onChange = nil
            return
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        isObserving = false
        onChange = nil
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        onChange?()
    }
}

@MainActor
public final class DisplayCatalog: DisplayCataloging {
    public typealias UUIDResolver = @MainActor @Sendable (
        CGDirectDisplayID
    ) -> UUID?

    private static let screenNumberKey = NSDeviceDescriptionKey(
        "NSScreenNumber"
    )

    private let provider: any ScreenProviding
    private let uuidResolver: UUIDResolver
    private var lastSnapshot: [DisplayDescriptor]?
    private var handler: (@MainActor @Sendable ([DisplayDescriptor]) -> Void)?
    private var isObserving = false

    public init(
        provider: any ScreenProviding = AppKitScreenProvider(),
        uuidResolver: @escaping UUIDResolver = DisplayCatalog.resolveUUID
    ) {
        self.provider = provider
        self.uuidResolver = uuidResolver
    }

    public func displays() -> [DisplayDescriptor] {
        makeSnapshot()
    }

    public func selectedDisplay(savedUUID: String?) -> DisplayDescriptor {
        let snapshot = makeSnapshot()
        if let savedUUID = Self.canonicalUUID(savedUUID),
           let selected = snapshot.first(where: { $0.id == savedUUID }) {
            return selected
        }
        guard let fallback = snapshot.first(where: \.isMain)
                ?? snapshot.first else {
            preconditionFailure("No usable macOS display is available.")
        }
        return fallback
    }

    public func startObserving(
        _ handler: @escaping @MainActor @Sendable ([DisplayDescriptor]) -> Void
    ) {
        if isObserving {
            stopObserving()
        }
        lastSnapshot = makeSnapshot()
        self.handler = handler
        provider.startObservingChanges { [weak self] in
            self?.refresh()
        }
        isObserving = true
    }

    public func stopObserving() {
        guard isObserving else {
            lastSnapshot = nil
            handler = nil
            return
        }
        provider.stopObservingChanges()
        isObserving = false
        lastSnapshot = nil
        handler = nil
    }

    private func refresh() {
        let snapshot = makeSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        handler?(snapshot)
    }

    private func makeSnapshot() -> [DisplayDescriptor] {
        let mainDisplayID = provider.mainScreen.flatMap(Self.displayID)
        return provider.screens.compactMap { screen in
            guard let displayID = Self.displayID(screen),
                  let uuid = uuidResolver(displayID) else {
                return nil
            }
            return DisplayDescriptor(
                id: uuid.uuidString.uppercased(),
                name: screen.localizedName,
                frame: screen.frame,
                scale: screen.backingScaleFactor,
                isMain: displayID == mainDisplayID
            )
        }
    }

    private static func displayID(
        _ screen: any ScreenRepresenting
    ) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[screenNumberKey]
                as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              let uuid = UUID(uuidString: value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              )) else {
            return nil
        }
        return uuid.uuidString.uppercased()
    }

    public nonisolated static func resolveUUID(
        _ displayID: CGDirectDisplayID
    ) -> UUID? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
        else {
            return nil
        }
        let displayUUID = unmanagedUUID.takeRetainedValue()
        guard let value = CFUUIDCreateString(nil, displayUUID) else {
            return nil
        }
        return UUID(uuidString: value as String)
    }
}
