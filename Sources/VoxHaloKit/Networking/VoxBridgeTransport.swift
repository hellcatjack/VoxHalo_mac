import Foundation

public enum VoxBridgeTransportMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
    case closed
}

public protocol VoxBridgeTransport: AnyObject, Sendable {
    func open() async throws
    func sendText(_ text: String) async throws
    func sendBinary(_ data: Data) async throws
    func receive() async throws -> VoxBridgeTransportMessage
    func close() async throws
}
