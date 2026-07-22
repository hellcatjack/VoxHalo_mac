import Foundation
import XCTest

@testable import VoxHaloKit

final class KeychainPasswordStoreTests: XCTestCase {
    func testGenericPasswordRoundTripsUpdatesAndDeletesInIsolatedService() throws {
        let store = KeychainPasswordStore(
            service: "com.hellcatjack.voxhalo.tests.\(UUID().uuidString)",
            account: "isolated-test"
        )
        defer { try? store.delete() }
        let first = SavedPassword(
            endpoint: "wss://example.test/ws",
            username: "operator",
            password: "synthetic-first"
        )
        let updated = SavedPassword(
            endpoint: "wss://example.test/ws",
            username: "operator",
            password: "synthetic-updated"
        )

        XCTAssertNil(try store.load())
        try store.save(first)
        XCTAssertEqual(try store.load(), first)
        try store.save(updated)
        XCTAssertEqual(try store.load(), updated)
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
