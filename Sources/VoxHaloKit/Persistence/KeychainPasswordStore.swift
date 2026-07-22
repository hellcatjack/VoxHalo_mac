import Foundation
import Security

public struct SavedPassword: Codable, Equatable, Sendable {
    public let endpoint: String
    public let username: String
    public let password: String

    public init(endpoint: String, username: String, password: String) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
    }
}

public protocol PasswordStoring: Sendable {
    func load() throws -> SavedPassword?
    func save(_ password: SavedPassword) throws
    func delete() throws
}

public struct KeychainPasswordStore: PasswordStoring, Sendable {
    public static let defaultService = "com.hellcatjack.voxhalo.voxbridge"
    public static let defaultAccount = "saved-password"

    private let service: String
    private let account: String

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> SavedPassword? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data else {
            throw KeychainPasswordStoreError(status: errSecDecode)
        }
        do {
            return try JSONDecoder().decode(SavedPassword.self, from: data)
        } catch {
            throw KeychainPasswordStoreError(status: errSecDecode)
        }
    }

    public func save(_ password: SavedPassword) throws {
        let data = try JSONEncoder().encode(password)
        let lookup =
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary
        let updateStatus = SecItemUpdate(
            lookup,
            [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainPasswordStoreError(status: updateStatus)
        }

        let addStatus = SecItemAdd(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary, nil)
        try check(addStatus)
    }

    public func delete() throws {
        let status = SecItemDelete(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw KeychainPasswordStoreError(status: status)
        }
    }
}

public struct KeychainPasswordStoreError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}
