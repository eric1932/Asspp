@testable import ApplePackage
import Foundation
import XCTest

final class BundledSAPTests: XCTestCase {
    func testActualBundledResourcesInitialize() async throws {
        guard ProcessInfo.processInfo.environment["ASSPP_TEST_BUNDLED_RESOURCES"] == "1" else {
            throw XCTSkip("Explicitly enable the bundled resource integration test in CI.")
        }
        #if canImport(CApplePackageSAP)
        XCTAssertTrue(NativeSAPMachine.usesBundledAssets, "This test must use the packaged resources, never the download cache")
        guard NativeSAPMachine.usesBundledAssets else { return }
        let machine = try await NativeSAPMachine.open(hardware: Data([2, 0, 0, 0, 0, 1]))
        do {
            try await machine.prepare()
            await machine.close()
        } catch {
            await machine.close()
            throw error
        }
        #else
        XCTFail("Bundled integration test requires the native runtime")
        #endif
    }
}
