import XCTest
@testable import VoxHaloKit

final class VoxHaloVersionTests: XCTestCase {
    func testProductIdentityIsStable() {
        XCTAssertEqual(VoxHaloVersion.productName, "VoxHalo")
        XCTAssertEqual(VoxHaloVersion.bundleIdentifier, "com.hellcatjack.voxhalo")
        XCTAssertEqual(VoxHaloVersion.minimumMacOS, "26.0")
    }
}
