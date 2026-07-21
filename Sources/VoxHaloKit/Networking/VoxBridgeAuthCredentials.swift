import Foundation

public struct VoxBridgeAuthCredentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.isEmpty ? "admin" : username
        self.password = password
    }

    public static func make(username: String?, password: String?) -> Self? {
        guard let password,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Self(username: username ?? "admin", password: password)
    }
}
