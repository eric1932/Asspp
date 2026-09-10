import ApplePackage
import Foundation
import XCTest

final class LiveSAPTests: XCTestCase {
    func testSignedAuthenticationWithFictionalCredentials() async throws {
        guard ProcessInfo.processInfo.environment["ASSPP_SAP_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Explicitly enable the live SAP probe; it downloads Apple's signing resources.")
        }
        do {
            _ = try await Authenticator.authenticate(email: "asspp-sap-probe@example.invalid", password: "not-a-real-apple-password")
            XCTFail("Fictional credentials must never authenticate")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .credentialsRejected, "Signed Swift request must reach credential validation")
        }
    }
}
