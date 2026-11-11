@testable import ApplePackage
import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

final class DeviceAttestationTests: XCTestCase {
    private struct FixedSigner: SAPRequestSigning {
        func sign(_: Data) async throws -> Data { Data([0x5A]) }
    }

    private struct FakeProvider: DeviceAttestationProviding {
        func machineHeaders(deviceIdentifier _: String) async throws -> [String: String] { [:] }
        func provisionStore(_: StoreProvisioningRequest) async throws -> StoreProvisioningResult { .init() }
        func storeHeaders(deviceIdentifier: String, url: URL) async throws -> [String: String] {
            ["X-Apple-AMD": "proof-\(deviceIdentifier)", "X-Apple-AMD-M": url.host ?? ""]
        }
    }

    private enum TestError: Error { case unexpectedBodyChunk }

    private func bodyData(_ request: HTTPClient.Request) throws -> Data {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let eventLoop = group.next()
        let captured = NIOLockedValueBox(Data())
        let body = try XCTUnwrap(request.body)
        try body.stream(
            .init { part in
                guard case let .byteBuffer(buffer) = part else { return eventLoop.makeFailedFuture(TestError.unexpectedBodyChunk) }
                captured.withLockedValue { $0.append(contentsOf: buffer.readableBytesView) }
                return eventLoop.makeSucceededFuture(())
            },
        ).wait()
        return captured.withLockedValue { $0 }
    }

    private func attempt(_ request: HTTPClient.Request) throws -> String? {
        let plist = try PropertyListSerialization.propertyList(from: bodyData(request), format: nil) as? [String: String]
        return plist?["attempt"]
    }

    func testLoginHeadersRenameMachineIdentityAndKeepTheRest() {
        let headers = DeviceAttestation.loginHeaders([
            "X-Apple-I-Md": "otp", "X-Apple-I-Md-M": "mid", "X-Apple-I-Md-Rinfo": "17106176", "X-Mme-Device-Id": "device",
        ])
        let names = headers.map { $0.0 }
        XCTAssertTrue(headers.contains { $0 == ("X-Apple-AMD", "otp") })
        XCTAssertTrue(headers.contains { $0 == ("X-Apple-AMD-M", "mid") })
        XCTAssertTrue(headers.contains { $0 == ("X-Apple-I-Md-Rinfo", "17106176") })
        XCTAssertTrue(headers.contains { $0 == ("X-Mme-Device-Id", "device") })
        XCTAssertFalse(names.contains { $0.caseInsensitiveCompare("X-Apple-I-MD") == .orderedSame })
        XCTAssertFalse(names.contains { $0.caseInsensitiveCompare("X-Apple-I-MD-M") == .orderedSame })

        // Store proof already uses the AMD names and passes through unchanged.
        let proof = DeviceAttestation.loginHeaders(["X-Apple-AMD": "a", "X-Apple-AMD-M": "m"])
        XCTAssertEqual(proof.map { $0.0 }, ["X-Apple-AMD", "X-Apple-AMD-M"])
    }

    func testRemovingMachineIdentityDropsOnlyTheThreeIdentityHeaders() {
        let remaining = DeviceAttestation.removingMachineIdentity([
            "x-apple-i-md": "otp", "X-Apple-I-MD-M": "mid", "X-Apple-I-Md-Rinfo": "1", "X-Apple-I-Md-Lu": "lu", "X-Mme-Device-Id": "d",
        ])
        XCTAssertEqual(Set(remaining.keys), ["X-Apple-I-Md-Lu", "X-Mme-Device-Id"])
    }

    func testCommerceURLWhitelistMatchesIpatool() throws {
        for good in [
            "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=A1B2C3D4E5F6",
            "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=A1B2C3D4E5F6",
            "https://downloaddispatch.itunes.apple.com/r/redownload?guid=A1B2C3D4E5F6",
            "https://downloaddispatch.itunes.apple.com/up/updateProduct?guid=A1B2C3D4E5F6",
            "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=A1B2C3D4E5F6",
        ] {
            XCTAssertTrue(try DeviceAttestation.isCommerceURL(XCTUnwrap(URL(string: good))), good)
        }
        for bad in [
            "http://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=A",
            "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct",
            "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=",
            "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=A&x=1",
            "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct?guid=A",
            "https://p9-buy.itunes.apple.com:8443/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=A",
            "https://pfoo-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=A",
            "https://downloaddispatch.itunes.apple.com/r/redownload?guid=A#fragment",
            "https://evil.example/r/redownload?guid=A",
        ] {
            XCTAssertFalse(try DeviceAttestation.isCommerceURL(XCTUnwrap(URL(string: bad))), bad)
        }
    }

    func testAttestedBagNormalizationFollowsIpatool() throws {
        let path = "/WebObjects/MZFinance.woa/wa/authenticate"
        let expectedPath = Bag.attestedLegacyTrailingSlash ? path + "/" : path
        for host in ["buy.itunes.apple.com", "p54-buy.itunes.apple.com"] {
            for original in ["https://\(host)\(path)", "https://\(host)\(path)/", "https://\(host)/other"] {
                XCTAssertEqual(Bag.attestedAuthEndpoint(from: original)?.absoluteString, "https://\(host)\(expectedPath)")
            }
        }
        XCTAssertEqual(
            Bag.attestedAuthEndpoint(from: "https://auth.itunes.apple.com/auth/v1/native")?.absoluteString,
            "https://auth.itunes.apple.com/auth/v1/native",
        )
        XCTAssertNil(Bag.attestedAuthEndpoint(from: "http://buy.itunes.apple.com\(path)"))

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["authenticateAccount": "https://auth.itunes.apple.com/auth/v1/native"], format: .xml, options: 0,
        )
        XCTAssertEqual(Bag.parse(plist, attested: true).authEndpoint.absoluteString, "https://auth.itunes.apple.com/auth/v1/native")
        XCTAssertEqual(Bag.parse(Data(), attested: true).authEndpoint, Bag.attestedDefaultAuthEndpoint)
    }

    func testUnattestedRequestKeepsThePreviousFormat() async throws {
        let request = try await Authenticator.makeRequest(
            endpoint: XCTUnwrap(URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=A1B2C3D4E5F6")),
            email: "reader@example.invalid", password: "secret", code: "", cookies: [], deviceIdentifier: "A1B2C3D4E5F6",
            sapSigner: FixedSigner(),
        )
        XCTAssertEqual(request.headers.map { $0.name }, ["User-Agent", "Content-Type", "X-Apple-ActionSignature"])
        XCTAssertEqual(request.headers.first(name: "User-Agent"), Configuration.userAgent)
        XCTAssertEqual(try attempt(request), "4")
    }

    func testAttestedRequestCarriesProofUserAgentAndAttemptCounter() async throws {
        let request = try await Authenticator.makeRequest(
            endpoint: XCTUnwrap(URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")),
            email: "reader@example.invalid", password: "secret", code: "123456", cookies: [], deviceIdentifier: "A1B2C3D4E5F6",
            sapSigner: FixedSigner(), attempt: "1", userAgent: DeviceAttestation.userAgent,
            extraHeaders: DeviceAttestation.loginHeaders(["X-Apple-AMD": "proof", "X-Apple-AMD-M": "machine"]),
        )
        XCTAssertEqual(
            request.headers.map { $0.name }, ["User-Agent", "Content-Type", "X-Apple-AMD", "X-Apple-AMD-M", "X-Apple-ActionSignature"],
        )
        XCTAssertEqual(request.headers.first(name: "User-Agent"), DeviceAttestation.userAgent)
        XCTAssertEqual(request.url.absoluteString, "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")
        XCTAssertEqual(try attempt(request), "1")
    }

    func testResponseDSIDFallbacks() {
        XCTAssertEqual(Authenticator.responseDSID(HTTPHeaders([("X-Dsid", " 123456 ")])), "123456")
        XCTAssertEqual(
            Authenticator.responseDSID(HTTPHeaders([("Set-Cookie", "itspod=9; path=/"), ("Set-Cookie", "mz_at0-987654=abc; path=/")])),
            "987654",
        )
        XCTAssertEqual(Authenticator.responseDSID(HTTPHeaders([("Set-Cookie", "x=1, mz_at_ssl-42=v")])), "42")
        XCTAssertNil(Authenticator.responseDSID(HTTPHeaders([("Set-Cookie", "notmz_at0-1=v")])))
    }

    func testDownloadProofOnlyWithProviderAndWhitelistedURL() async throws {
        let previousProvider = Configuration.deviceAttestationProvider
        let previousIdentifier = Configuration.deviceIdentifier
        defer {
            Configuration.deviceAttestationProvider = previousProvider
            Configuration.deviceIdentifier = previousIdentifier
        }
        let download = try XCTUnwrap(URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload?guid=A1B2C3D4E5F6"))
        let purchase = try XCTUnwrap(URL(string: "https://p9-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct?guid=A1B2C3D4E5F6"))

        Configuration.deviceAttestationProvider = nil
        let none = try await DeviceAttestation.storeHeaders(for: download)
        XCTAssertTrue(none.isEmpty)

        Configuration.deviceIdentifier = "A1B2C3D4E5F6"
        Configuration.deviceAttestationProvider = FakeProvider()
        let proof = try await DeviceAttestation.storeHeaders(for: download)
        XCTAssertEqual(proof, ["X-Apple-AMD": "proof-A1B2C3D4E5F6", "X-Apple-AMD-M": "downloaddispatch.itunes.apple.com"])
        let skipped = try await DeviceAttestation.storeHeaders(for: purchase)
        XCTAssertTrue(skipped.isEmpty)
    }

    func testHardwareIdentifierValidation() {
        XCTAssertTrue(DeviceAttestation.isHardwareIdentifier("06050F1CFDA2"))
        XCTAssertTrue(DeviceAttestation.isHardwareIdentifier("a1b2c3d4e5f6"))
        XCTAssertFalse(DeviceAttestation.isHardwareIdentifier("06:05:0F:1C:FD:A2"))
        XCTAssertFalse(DeviceAttestation.isHardwareIdentifier("06050F1CFDA"))
        XCTAssertFalse(DeviceAttestation.isHardwareIdentifier("06050F1CFDAZ"))
    }
}
