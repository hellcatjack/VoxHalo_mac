import AppKit
import CoreGraphics
import Foundation
@testable import VoxHaloKit

@MainActor
final class FakeScreen: ScreenRepresenting {
    let number: CGDirectDisplayID
    let localizedName: String
    let frame: NSRect
    let backingScaleFactor: CGFloat

    init(
        number: CGDirectDisplayID,
        localizedName: String,
        frame: NSRect,
        backingScaleFactor: CGFloat
    ) {
        self.number = number
        self.localizedName = localizedName
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
    }

    var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [
            NSDeviceDescriptionKey("NSScreenNumber"):
                NSNumber(value: number)
        ]
    }
}

@MainActor
final class FakeScreenProvider: ScreenProviding {
    private var storedScreens: [FakeScreen]
    private var mainNumber: CGDirectDisplayID?
    private var observer: (@MainActor @Sendable () -> Void)?

    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0

    init(
        screens: [FakeScreen],
        mainNumber: CGDirectDisplayID? = nil
    ) {
        storedScreens = screens
        self.mainNumber = mainNumber ?? screens.first?.number
    }

    var screens: [any ScreenRepresenting] {
        storedScreens
    }

    var mainScreen: (any ScreenRepresenting)? {
        guard let mainNumber else { return storedScreens.first }
        return storedScreens.first { $0.number == mainNumber }
            ?? storedScreens.first
    }

    func startObservingChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        observer = onChange
        startObservingCount += 1
    }

    func stopObservingChanges() {
        observer = nil
        stopObservingCount += 1
    }

    func replaceScreens(
        _ screens: [FakeScreen],
        mainNumber: CGDirectDisplayID? = nil,
        notify: Bool = true
    ) {
        storedScreens = screens
        self.mainNumber = mainNumber ?? screens.first?.number
        if notify {
            observer?()
        }
    }

    func notifyWithoutChange() {
        observer?()
    }
}
