@testable import ApplePackage
import Foundation
import XCTest

private let testGUID = "02000000abCD"
private let authURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
private let sapConfig = SAPConfiguration(version: 200, setupURL: URL(string: "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy")!, certificateURL: URL(string: "https://s.mzstatic.com/sap/setupCert.plist")!)

private func plist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private func bagValues() -> [String: Any] {
    ["authenticateAccount": authURL, "sign-sap-version": 200, "sign-sap-setup": sapConfig.setupURL.absoluteString, "sign-sap-setup-cert": sapConfig.certificateURL.absoluteString]
}

private func bagResponse() throws -> AuthenticationResponse { try AuthenticationResponse(body: plist(bagValues())) }
private func successResponse() throws -> AuthenticationResponse {
    try AuthenticationResponse(headers: [("x-set-apple-store-front", "143441-1,29")], body: plist([
        "accountInfo": ["appleId": "user@example.invalid", "address": ["firstName": "Test", "lastName": "User"]],
        "passwordToken": "test-token", "dsPersonId": "1234",
    ]))
}

private enum TestFailure: Error, Equatable { case exhausted, timeout, signing }

private actor ScriptedTransport: AuthenticationTransport {
    var results: [Result<AuthenticationResponse, Error>]
    var requests: [AuthenticationRequest] = []
    var closes = 0
    init(_ responses: [AuthenticationResponse]) { results = responses.map { .success($0) } }
    init(results: [Result<AuthenticationResponse, Error>]) { self.results = results }
    func send(_ request: AuthenticationRequest) async throws -> AuthenticationResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard !results.isEmpty else { throw TestFailure.exhausted }
        return try results.removeFirst().get()
    }
    func close() { closes += 1 }
}

private actor RecordingSigner: ActionSigner {
    var inputs: [Data] = []
    var closes = 0
    var failure: TestFailure?
    var block: Bool
    init(failure: TestFailure? = nil, block: Bool = false) { self.failure = failure; self.block = block }
    func sign(_ data: Data) async throws -> Data {
        inputs.append(data)
        if block { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if let failure { throw failure }
        return Data([0, 255, UInt8(inputs.count)])
    }
    func close() { closes += 1 }
}

private actor RecordingMachine: SAPMachine {
    var states: [Int32]
    var exchanges: [Data] = []
    var prepares = 0
    var closes = 0
    init(states: [Int32] = [1, 0]) { self.states = states }
    func prepare() { prepares += 1 }
    func exchange(version: UInt32, data: Data) throws -> (data: Data, state: Int32) {
        guard version == 200, !states.isEmpty else { throw TestFailure.exhausted }
        exchanges.append(data)
        return (Data([42]), states.removeFirst())
    }
    func sign(_ data: Data) -> Data { Data([1, 2, 3]) }
    func close() { closes += 1 }
}

@MainActor
final class OfflineAuthenticationTests: XCTestCase {
    private func environment(_ transport: ScriptedTransport, _ signer: RecordingSigner) -> AuthenticationEnvironment {
        AuthenticationEnvironment(deviceIdentifier: testGUID, userAgent: "OfflineTest/1", transport: transport, makeSigner: { configuration, hardware, _, _, _ in
            guard configuration == sapConfig, hardware == Data([2, 0, 0, 0, 171, 205]) else { throw TestFailure.signing }
            return signer
        })
    }

    func testBagAcceptsRootNestedAndWrappedFormats() throws {
        let root = try plist(bagValues())
        for data in [root, try plist(["urlBag": bagValues()]), Data("<Document><Protocol>".utf8) + root + Data("</Protocol></Document>".utf8)] {
            let parsed = try Bag.parse(data)
            XCTAssertEqual(parsed.authEndpoint.absoluteString, authURL)
            XCTAssertEqual(parsed.sap, sapConfig)
        }
        var values = bagValues()
        values["sign-sap-version"] = "200"
        values["authenticateAccount"] = "https://auth.itunes.apple.com/auth/v1/native"
        XCTAssertEqual(try Bag.parse(plist(values)).authEndpoint.absoluteString, "https://auth.itunes.apple.com/auth/v1/native/fast/")
    }

    func testBagNeverFallsBackToUnsignedConfiguration() throws {
        for key in ["sign-sap-version", "sign-sap-setup", "sign-sap-setup-cert"] {
            var values = bagValues(); values.removeValue(forKey: key)
            XCTAssertThrowsError(try Bag.parse(plist(values))) { XCTAssertEqual($0 as? AuthenticationError, .missingSAPConfiguration) }
        }
        var unknown = bagValues(); unknown["sign-sap-version"] = 201
        XCTAssertThrowsError(try Bag.parse(plist(unknown))) { XCTAssertEqual($0 as? AuthenticationError, .unsupportedSAPVersion(201)) }
        XCTAssertThrowsError(try Bag.parse(Data()))
        XCTAssertThrowsError(try Bag.parse(Data("not a plist".utf8)))
    }

    func testBagRejectsUntrustedOrInsecureEndpoints() throws {
        for endpoint in ["http://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate", "https://buy.itunes.apple.com.evil.invalid/auth", "https://user:password@buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"] {
            var values = bagValues(); values["authenticateAccount"] = endpoint
            XCTAssertThrowsError(try Bag.parse(plist(values)))
        }
        var values = bagValues(); values["sign-sap-setup"] = "https://untrusted.invalid/setup"
        XCTAssertThrowsError(try Bag.parse(plist(values)))
    }

    func testSignedBytesRedirectCookiesPodAndAccountCompatibility() async throws {
        let cookie = Cookie(name: "session", value: "offline", path: "/", domain: ".itunes.apple.com", httpOnly: true, secure: true)
        let redirect = AuthenticationResponse(status: 302, headers: [("Location", "https://p71-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"), ("pod", "71")], cookies: [cookie])
        let transport = try ScriptedTransport([bagResponse(), redirect, successResponse()])
        let signer = RecordingSigner()
        let password = "<&\"'你好🔑"
        let account = try await Authenticator.authenticate(email: "a&b@example.invalid", password: password, cookies: [], environment: environment(transport, signer))
        let requests = await transport.requests
        let signed = await signer.inputs
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(signed.count, 2)
        XCTAssertEqual(signed[0], signed[1])
        for index in 1 ... 2 {
            XCTAssertEqual(requests[index].method, "POST")
            XCTAssertEqual(requests[index].body, signed[index - 1])
            XCTAssertEqual(requests[index].headers.first { $0.0 == "X-Apple-ActionSignature" }?.1, Data([0, 255, UInt8(index)]).base64EncodedString())
        }
        let sent = try AuthenticationValidation.plist(XCTUnwrap(requests[1].body))
        XCTAssertEqual(sent["password"] as? String, password)
        XCTAssertEqual(sent["appleId"] as? String, "a&b@example.invalid")
        XCTAssertEqual(sent["guid"] as? String, testGUID)
        XCTAssertEqual(sent["attempt"] as? String, "1")
        XCTAssertEqual(requests[2].headers.first { $0.0 == "Cookie" }?.1, "session=offline")
        XCTAssertEqual(account.pod, "71")
        XCTAssertEqual(account.store, "143441")
        XCTAssertEqual(account.password, password)
        XCTAssertEqual(account.cookie, [cookie])
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account)), account)
        let signerCloses = await signer.closes; let transportCloses = await transport.closes
        XCTAssertEqual(signerCloses, 1); XCTAssertEqual(transportCloses, 1)
    }

    func testVerificationCodeChangesTheSignedBody() async throws {
        var bodies: [Data] = []
        for code in ["", "123456", "123 456\n"] {
            let transport = try ScriptedTransport([bagResponse(), successResponse()]); let signer = RecordingSigner()
            let account = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", code: code, environment: environment(transport, signer))
            let inputs = await signer.inputs
            let body = try XCTUnwrap(inputs.first); bodies.append(body)
            let values = try AuthenticationValidation.plist(body)
            XCTAssertEqual(values["password"] as? String, "secret" + (code.isEmpty ? "" : "123456"))
            XCTAssertEqual(values["attempt"] as? String, "1")
            XCTAssertEqual(account.password, "secret", "Never save the one-time code as part of the password")
            let requests = await transport.requests
            XCTAssertEqual(requests[1].body, body)
        }
        XCTAssertNotEqual(bodies[0], bodies[1])
    }

    func testCredentialFollowupIsResignedAndPreservesRedirectState() async throws {
        let podURL = "https://p71-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        let cookie = Cookie(name: "session", value: "followup", path: "/", domain: ".itunes.apple.com", httpOnly: true, secure: true)
        let redirect = AuthenticationResponse(status: 302, headers: [("Location", podURL), ("pod", "71")])
        let followup = try AuthenticationResponse(body: plist(["failureType": "-5000", "customerMessage": "MZFinance.BadLogin.Configurator_message"]), cookies: [cookie])
        let transport = try ScriptedTransport([bagResponse(), redirect, followup, redirect, successResponse()])
        let signer = RecordingSigner()
        let account = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment(transport, signer))
        let allRequests = await transport.requests
        let requests = Array(allRequests.dropFirst())
        let inputs = await signer.inputs
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(inputs.count, 4)
        XCTAssertEqual(inputs[0], inputs[1])
        XCTAssertEqual(inputs[2], inputs[3])
        XCTAssertNotEqual(inputs[1], inputs[2])
        for index in requests.indices {
            XCTAssertEqual(requests[index].body, inputs[index])
            let values = try AuthenticationValidation.plist(inputs[index])
            XCTAssertEqual(values["attempt"] as? String, index < 2 ? "1" : "2")
            XCTAssertEqual(requests[index].headers.first { $0.0 == "X-Apple-ActionSignature" }?.1, Data([0, 255, UInt8(index + 1)]).base64EncodedString())
        }
        XCTAssertEqual(requests[2].url.absoluteString, podURL)
        XCTAssertEqual(requests[2].headers.first { $0.0 == "Cookie" }?.1, "session=followup")
        XCTAssertEqual(account.cookie, [cookie])
        XCTAssertEqual(account.pod, "71")
        let closes = await signer.closes
        XCTAssertEqual(closes, 1)
    }

    func testEmpty403IsTerminalAndReleasesResources() async throws {
        let transport = try ScriptedTransport([bagResponse(), AuthenticationResponse(status: 403)])
        let signer = RecordingSigner()
        do {
            _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment(transport, signer))
            XCTFail("403 must fail")
        } catch { XCTAssertEqual(error as? AuthenticationError, .requestRejected(status: 403)) }
        let count = await transport.requests.count; let closes = await signer.closes; let transportCloses = await transport.closes
        XCTAssertEqual(count, 2); XCTAssertEqual(closes, 1); XCTAssertEqual(transportCloses, 1)
    }

    func testBadCredentialsAreNotAssumedToBeTwoFactorChallenge() async throws {
        for (failure, code, expected) in [("", "", AuthenticationError.credentialsRejected), ("5005", "123456", .invalidVerificationCode), ("-5000", "", .credentialsRejected), ("-5000", "123456", .credentialsRejected)] {
            let response = try AuthenticationResponse(body: plist(["failureType": failure, "customerMessage": "MZFinance.BadLogin.Configurator_message"]))
            let transport = try ScriptedTransport([bagResponse(), response] + (failure == "-5000" ? [response] : [])); let signer = RecordingSigner()
            do {
                _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", code: code, environment: environment(transport, signer))
                XCTFail("Expected an authentication failure")
            } catch { XCTAssertEqual(error as? AuthenticationError, expected) }
            let requests = await transport.requests.count
            XCTAssertEqual(requests, failure == "-5000" ? 3 : 2, "Credential follow-up is allowed only once")
            let signerCloses = await signer.closes; let transportCloses = await transport.closes
            XCTAssertEqual(signerCloses, 1); XCTAssertEqual(transportCloses, 1)
        }
    }

    func testEmpty403AfterCredentialFollowupIsStillTerminal() async throws {
        let response = try AuthenticationResponse(body: plist(["failureType": "-5000"]))
        let transport = try ScriptedTransport([bagResponse(), response, AuthenticationResponse(status: 403)])
        let signer = RecordingSigner()
        do {
            _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment(transport, signer))
            XCTFail("Expected a terminal rejection")
        } catch { XCTAssertEqual(error as? AuthenticationError, .requestRejected(status: 403)) }
        let requests = await transport.requests.count; let closes = await signer.closes
        XCTAssertEqual(requests, 3); XCTAssertEqual(closes, 1)
    }

    func testTimeoutDoesNotRepeatCredentials() async throws {
        let transport = try ScriptedTransport(results: [.success(bagResponse()), .failure(TestFailure.timeout)])
        let signer = RecordingSigner()
        do {
            _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment(transport, signer))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? TestFailure, .timeout) }
        let count = await transport.requests.count; let closes = await signer.closes
        XCTAssertEqual(count, 2); XCTAssertEqual(closes, 1)
    }

    func testSigningFailureSendsNoCredentials() async throws {
        let transport = try ScriptedTransport([bagResponse()]); let signer = RecordingSigner(failure: .signing)
        do {
            _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment(transport, signer))
            XCTFail("Expected signing failure")
        } catch { XCTAssertEqual(error as? TestFailure, .signing) }
        let count = await transport.requests.count; let closes = await signer.closes
        XCTAssertEqual(count, 1); XCTAssertEqual(closes, 1)
    }

    func testSignerInitializationFailureClosesTransportWithoutSendingCredentials() async throws {
        let transport = try ScriptedTransport([bagResponse()]); let signer = RecordingSigner()
        var environment = environment(transport, signer)
        environment.makeSigner = { _, _, _, _, _ in throw TestFailure.signing }
        do {
            _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment)
            XCTFail("Expected signer initialization failure")
        } catch { XCTAssertEqual(error as? TestFailure, .signing) }
        let count = await transport.requests.count; let closes = await transport.closes
        XCTAssertEqual(count, 1); XCTAssertEqual(closes, 1)
    }

    func testRefreshCookiesAreSentAndUpdatedWithoutDuplicates() async throws {
        let old = Cookie(name: "session", value: "old", path: "/", domain: ".iTunes.apple.com", httpOnly: true, secure: true)
        var new = old; new.value = "new"; new.domain = "itunes.apple.com"
        var response = try successResponse(); response.cookies = [new]
        let transport = try ScriptedTransport([bagResponse(), response]); let signer = RecordingSigner()
        let account = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", cookies: [old], environment: environment(transport, signer))
        let requests = await transport.requests
        XCTAssertEqual(requests[1].headers.first { $0.0 == "Cookie" }?.1, "session=old")
        XCTAssertEqual(account.cookie, [new])
        XCTAssertEqual(account.password, "secret")
    }

    func testCancellationDuringSigningClosesWithoutSendingCredentials() async throws {
        let transport = try ScriptedTransport([bagResponse()]); let signer = RecordingSigner(block: true)
        let environment = environment(transport, signer)
        let task = Task { try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment) }
        while await signer.inputs.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count; let closes = await signer.closes; let transportCloses = await transport.closes
        XCTAssertEqual(count, 1); XCTAssertEqual(closes, 1); XCTAssertEqual(transportCloses, 1)
    }

    func testRedirectCannotLeakCredentialsAndLoopsAreBounded() async throws {
        for endpoint in ["https://example.invalid/login", authURL] {
            let redirect = AuthenticationResponse(status: 307, headers: [("Location", endpoint)])
            let transport = try ScriptedTransport([bagResponse(), redirect, redirect, redirect, redirect])
            let signer = RecordingSigner()
            do {
                _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment(transport, signer))
                XCTFail("Expected rejected redirect")
            } catch { XCTAssertEqual(error as? AuthenticationError, endpoint == authURL ? .tooManyRedirects : .invalidEndpoint) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, endpoint == authURL ? 5 : 2)
            XCTAssertTrue(requests.allSatisfy { $0.url.host != "example.invalid" })
        }
    }

    func testInvalidDeviceAndBagCloseTransportWithoutSigning() async throws {
        for guid in ["not-a-guid", testGUID] {
            let transport = ScriptedTransport([AuthenticationResponse()]); let signer = RecordingSigner()
            var environment = environment(transport, signer); environment.deviceIdentifier = guid
            do {
                _ = try await Authenticator.authenticate(email: "test@example.invalid", password: "secret", environment: environment)
                XCTFail("Expected invalid configuration")
            } catch { XCTAssertEqual(error as? AuthenticationError, guid == testGUID ? .invalidResponse : .invalidDeviceIdentifier) }
            let count = await signer.inputs.count; let closes = await transport.closes
            XCTAssertEqual(count, 0); XCTAssertEqual(closes, 1)
        }
    }

    func testSAPHandshakeTransportsBinaryDataAndReleasesOnFailure() async throws {
        let certificate = Data([0, 255, 1]); let setup = Data([4, 5, 6])
        for states: [Int32] in [[1, 0], [0], [1, 1]] {
            let machine = RecordingMachine(states: states)
            let transport = try ScriptedTransport([AuthenticationResponse(body: plist(["sign-sap-setup-cert": certificate])), AuthenticationResponse(body: plist(["sign-sap-setup-buffer": setup]))])
            do {
                let signer = try await LocalSAPSigner.prepare(machine: machine, configuration: sapConfig, transport: transport, userAgent: "OfflineTest/1")
                XCTAssertEqual(states, [1, 0])
                await signer.close()
                let requests = await transport.requests
                let body = try XCTUnwrap(requests[1].body)
                XCTAssertEqual(try AuthenticationValidation.plist(body)["sign-sap-setup-buffer"] as? Data, Data([42]))
                let exchanges = await machine.exchanges
                XCTAssertEqual(exchanges, [certificate, setup])
            } catch { XCTAssertNotEqual(states, [1, 0]) }
            let closes = await machine.closes
            XCTAssertEqual(closes, 1)
        }
    }

    func testSAPHandshakeMissingCertificateReleasesMachine() async throws {
        let machine = RecordingMachine(); let transport = try ScriptedTransport([AuthenticationResponse(body: plist([:]))])
        do {
            _ = try await LocalSAPSigner.prepare(machine: machine, configuration: sapConfig, transport: transport, userAgent: "OfflineTest/1")
            XCTFail("Expected missing certificate")
        } catch { XCTAssertEqual(error as? AuthenticationError, .invalidResponse) }
        let closes = await machine.closes; let exchanges = await machine.exchanges
        XCTAssertEqual(closes, 1); XCTAssertTrue(exchanges.isEmpty)
    }

    func testSensitiveHeadersAreRedactedInBothDirections() {
        for name in ["Cookie", "Set-Cookie", "X-Apple-ActionSignature", "Authorization", "X-Token", "Password"] {
            XCTAssertEqual(APLogger.redactedHeader(name, value: "secret"), "<redacted>")
        }
        XCTAssertEqual(APLogger.redactedHeader("Content-Type", value: "application/xml"), "application/xml")
    }
}
