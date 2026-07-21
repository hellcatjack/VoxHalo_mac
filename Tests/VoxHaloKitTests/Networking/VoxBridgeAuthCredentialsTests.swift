import XCTest
@testable import VoxHaloKit

final class VoxBridgeAuthCredentialsTests: XCTestCase {
    func testBlankPasswordProducesNoCredentials() {
        XCTAssertNil(VoxBridgeAuthCredentials.make(username: "operator", password: nil))
        XCTAssertNil(VoxBridgeAuthCredentials.make(username: "operator", password: ""))
        XCTAssertNil(VoxBridgeAuthCredentials.make(username: "operator", password: " \n\t "))
    }

    func testBlankUsernameDefaultsToAdminAndNonblankUsernameIsTrimmed() throws {
        XCTAssertEqual(
            try XCTUnwrap(VoxBridgeAuthCredentials.make(username: nil, password: "p")).username,
            "admin"
        )
        XCTAssertEqual(
            try XCTUnwrap(VoxBridgeAuthCredentials.make(username: "  ", password: "p")).username,
            "admin"
        )
        XCTAssertEqual(
            try XCTUnwrap(VoxBridgeAuthCredentials.make(
                username: "  operator name  ",
                password: "p"
            )).username,
            "operator name"
        )
    }

    func testPasswordIsPreservedVerbatimAfterNonblankCheck() throws {
        let password = "  p&ss=word \n"
        let credentials = try XCTUnwrap(
            VoxBridgeAuthCredentials.make(username: "operator", password: password)
        )

        XCTAssertEqual(credentials.password, password)
    }
}
