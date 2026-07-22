import CoreGraphics
import Foundation

public struct DisplayDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let frame: CGRect
    public let scale: CGFloat
    public let isMain: Bool

    public init(
        id: String,
        name: String,
        frame: CGRect,
        scale: CGFloat,
        isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
        self.isMain = isMain
    }
}
