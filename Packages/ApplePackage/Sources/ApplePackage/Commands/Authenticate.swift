//
//  Authenticate.swift
//  ApplePackage
//
//  Created by QAQ on 2023/10/4.
//

import AsyncHTTPClient
import Foundation
import NIOHTTP1

public actor Authenticator {
    private enum LoginResponse {
        case success(Account)
        case codeRequired
        case redirect(URL)
        case retry
        case failure(String)
    }

    private enum LoginOutcome {
        case account(Account)
        /// Apple asked for a machine provisioning step (`X-Apple-AMD-Action`), with its `X-Apple-AMD-Data`.
        case machineAction(String, String)
    }

    private let signer: SAPSigner
    private let deviceIdentifier: String
    private let attestation: (any DeviceAttestationProviding)?
    private let userAgent: String
    /// Attested sign-in always starts here (ipatool keeps redirects per attempt).
    private let baseEndpoint: URL
    /// Unattested sign-in keeps the last redirect target across calls.
    private var endpoint: URL
    private var cookies: [Cookie]
    private var storeFront = ""
    private var pod: String?
    private var authenticating = false

    /// A fresh SAP exchange is mandatory. Reuse this instance when supplying a verification code.
    /// - Parameter attestation: device attestation for Apple's November 2026 sign-in; `nil` keeps
    ///   the previous request format.
    public init(cookies: [Cookie] = [], attestation: (any DeviceAttestationProviding)? = Configuration.deviceAttestationProvider) async throws {
        let identifier = Configuration.deviceIdentifier
        let base: URL
        if attestation != nil {
            guard DeviceAttestation.isHardwareIdentifier(identifier) else {
                try ensureFailed("Device attestation requires a 12-digit hexadecimal device identifier.")
            }
            let bag = try await Bag.fetchBag(redirectConfiguration: .disallow, attested: true)
            base = try Self.approvedEndpoint(bag.authEndpoint)
            APLogger.info("auth: attested endpoint \(APLogger.safeURL(base.absoluteString)) slash=\(Self.hasTrailingSlash(base))")
            userAgent = DeviceAttestation.userAgent
        } else {
            let bag = try await Bag.fetchBag(redirectConfiguration: .disallow)
            base = try Self.createInitialRequestEndpoint(baseURL: bag.authEndpoint, deviceIdentifier: identifier)
            userAgent = Configuration.userAgent
        }
        deviceIdentifier = identifier
        self.attestation = attestation
        baseEndpoint = base
        endpoint = base
        signer = try await SAPSigner.connect()
        self.cookies = cookies
    }

    public static func authenticate(email: String, password: String, code: String = "", cookies: [Cookie] = []) async throws -> Account {
        let session = try await Authenticator(cookies: cookies)
        return try await session.authenticate(email: email, password: password, code: code)
    }

    public func authenticate(email: String, password: String, code: String = "") async throws -> Account {
        guard !authenticating else { try ensureFailed("An authentication request is already in progress.") }
        authenticating = true
        defer { authenticating = false }
        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer { _ = client.shutdown() }

        guard let attestation else {
            switch try await login(client: client, email: email, password: password, code: code, machineHeaders: [:]) {
            case let .account(account): return account
            case .machineAction: throw AuthenticationError.deviceAttestationRequired
            }
        }
        return try await attestedLogin(attestation, client: client, email: email, password: password, code: code)
    }

    /// ipatool 2.8.0's sequence: existing Store proof, else machine headers (Apple answers RP),
    /// then no machine identity (Apple answers SP with a challenge), Store provisioning, Store proof.
    private func attestedLogin(
        _ attestation: any DeviceAttestationProviding, client: HTTPClient, email: String, password: String, code: String,
    ) async throws -> Account {
        do {
            let proof = try await attestation.storeHeaders(deviceIdentifier: deviceIdentifier, url: baseEndpoint)
            APLogger.info("auth: stage 0, existing Store proof")
            switch try await login(client: client, email: email, password: password, code: code, machineHeaders: proof) {
            case let .account(account): return account
            case let .machineAction(action, _): APLogger.info("auth: stage 0 answered with machine action \(action), provisioning again")
            }
        } catch DeviceAttestationError.notProvisioned {
            APLogger.info("auth: stage 0 skipped, device not provisioned")
        }

        APLogger.info("auth: stage 1, machine headers")
        let machine = try await attestation.machineHeaders(deviceIdentifier: deviceIdentifier)
        let first = try await login(client: client, email: email, password: password, code: code, machineHeaders: machine)
        guard case let .machineAction(firstAction, _) = first else { return try Self.account(first) }
        guard firstAction == "RP" else { try ensureFailed("\(Strings.authFailed): unexpected machine action \(firstAction)") }

        APLogger.info("auth: stage 2, without machine identity")
        let second = try await login(
            client: client, email: email, password: password, code: code, machineHeaders: DeviceAttestation.removingMachineIdentity(machine),
        )
        guard case let .machineAction(secondAction, challenge) = second else { return try Self.account(second) }
        guard secondAction == "SP", !challenge.isEmpty else {
            try ensureFailed("\(Strings.authFailed): unexpected machine action \(secondAction)")
        }

        APLogger.info("auth: stage 3, Store provisioning")
        let result = try await attestation.provisionStore(.init(
            deviceIdentifier: deviceIdentifier, challenge: challenge, endpoint: DeviceAttestation.storeProvisioningEndpoint,
            userAgent: userAgent, machineHeaders: machine, cookies: cookies,
        ))
        cookies.mergeCookies(result.cookies)
        let proof = try await attestation.storeHeaders(deviceIdentifier: deviceIdentifier, url: baseEndpoint)
        let third = try await login(client: client, email: email, password: password, code: code, machineHeaders: proof)
        guard case let .account(account) = third else {
            try ensureFailed("\(Strings.authFailed): Apple still requires device provisioning")
        }
        return account
    }

    private static func account(_ outcome: LoginOutcome) throws -> Account {
        guard case let .account(account) = outcome else { try ensureFailed(Strings.authFailedUnknown) }
        return account
    }

    /// One sign-in attempt: follows redirects, retries edge rejections and `-5000`, and stops at a
    /// result or a machine action.
    private func login(
        client: HTTPClient, email: String, password: String, code: String, machineHeaders: [String: String],
    ) async throws -> LoginOutcome {
        let attested = attestation != nil
        let extraHeaders = DeviceAttestation.loginHeaders(machineHeaders)
        var target = attested ? baseEndpoint : endpoint
        var retried = false
        var redirects = 0
        var edgeRejections = 0
        var attempt = 1
        for _ in 0 ..< 14 {
            // Unattested requests try the trailing-slash form on every third edge retry. Attested
            // requests keep the exact URL their Store proof was issued for.
            let slash = !attested && edgeRejections % 3 == 2
            let requestURL = attested ? target : Bag.legacyAuthEndpoint(target, trailingSlash: slash)
            let request = try await Self.makeRequest(
                endpoint: requestURL, email: email, password: password, code: code, cookies: cookies, deviceIdentifier: deviceIdentifier,
                sapSigner: signer, attempt: attested ? String(attempt) : nil, userAgent: userAgent, extraHeaders: extraHeaders,
            )
            let accumulator = ResponseAccumulator(request: request, maxBodySize: 2 * 1024 * 1024)
            let response = try await client.execute(request: request, delegate: accumulator).futureResult.get()
            let action = Self.machineAction(response)
            // DEBUG BUILD: trace every authentication round trip without credentials or header values.
            let machineLabel = machineHeaders.isEmpty ? "none" : String(machineHeaders.count) + " headers"
            let codeLabel = code.isEmpty ? "password" : "password+code"
            let backend = response.headers.contains(name: "x-apple-jingle-correlation-key")
            APLogger.info(
                "auth: POST \(APLogger.safeURL(requestURL.absoluteString)) slash=\(Self.hasTrailingSlash(requestURL)) attempt=\(attempt) machine=\(machineLabel) [\(codeLabel)] -> HTTP \(response.status.code), \(response.body?.readableBytes ?? 0) bytes, backend=\(backend), action=\(action?.0 ?? "none")",
            )
            // Only edge HTML error pages; store plists (even redirects) echo the Apple ID.
            if response.status != .ok, let body = response.body, body.readableBytes > 0,
               response.headers.first(name: "content-type")?.lowercased().contains("text/html") == true
            {
                APLogger.info("auth: non-200 html body: \(String(decoding: body.readableBytesView.prefix(300), as: UTF8.self))")
            }
            if let action {
                cookies.mergeCookies(response.cookies)
                return .machineAction(action.0, action.1)
            }
            if Self.isEdgeRejection(response) {
                edgeRejections += 1
                guard edgeRejections < Self.maxEdgeRejections else {
                    if !attested { throw AuthenticationError.deviceAttestationRequired }
                    try ensureFailed("\(Strings.authFailed): Apple's edge rejected the request \(edgeRejections) times (last HTTP \(response.status.code))")
                }
                APLogger.info("auth: edge rejection (HTTP \(response.status.code), no store backend headers), retry \(edgeRejections)")
                try await Task.sleep(nanoseconds: UInt64(edgeRejections) * 250_000_000)
                continue
            }
            let result = try parseResponse(response, email: email, password: password, code: code)
            switch result {
            case let .success(account): return .account(account)
            case let .redirect(url):
                guard redirects < 4 else { try ensureFailed("Authentication redirect limit exceeded.") }
                guard let resolved = URL(string: url.relativeString, relativeTo: target)?.absoluteURL else {
                    try ensureFailed(Strings.failedToRetrieveRedirect)
                }
                // Attested redirects change only the destination; the payload and Store proof stay.
                let next = attested ? resolved : (Bag.normalizedAuthEndpoint(from: resolved.absoluteString) ?? resolved)
                APLogger.info("auth: redirect \(response.status.code) to \(APLogger.safeURL(next.absoluteString))")
                target = try Self.approvedEndpoint(next)
                if !attested { endpoint = target }
                redirects += 1
            case .codeRequired: throw AuthenticationError.verificationCodeRequired
            case .retry:
                guard !retried else { try ensureFailed(Strings.authFailedUnknown) }
                retried = true
                attempt += 1
            case let .failure(message): try ensureFailed("\(Strings.authFailed): \(message)")
            }
        }
        try ensureFailed("Authentication attempt limit exceeded.")
    }

    static let maxEdgeRejections = 6

    /// Apple's edge answers some authentication requests itself (empty 204, HTML 301 without
    /// Location, 404, 503) without reaching the store backend, which always tags its responses
    /// with a Jingle correlation key. Those are routing failures, not authentication results.
    static func isEdgeRejection(_ response: HTTPClient.Response) -> Bool {
        guard response.status != .ok, !response.headers.contains(name: "x-apple-jingle-correlation-key") else { return false }
        let redirectStatuses: [HTTPResponseStatus] = [.movedPermanently, .found, .seeOther, .temporaryRedirect, .permanentRedirect]
        if redirectStatuses.contains(response.status), response.headers.first(name: "location") != nil { return false }
        return true
    }

    /// `X-Apple-AMD-Action` takes precedence over status and body, as in ipatool.
    static func machineAction(_ response: HTTPClient.Response) -> (String, String)? {
        guard let action = response.headers.first(name: "X-Apple-AMD-Action")?.trimmingCharacters(in: .whitespaces), !action.isEmpty else {
            return nil
        }
        return (action, response.headers.first(name: "X-Apple-AMD-Data")?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    static func hasTrailingSlash(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: true)?.path.hasSuffix("/") ?? false
    }

    public static func rotatePasswordToken(for account: inout Account) async throws {
        account = try await authenticate(email: account.email, password: account.password, cookies: account.cookie)
    }

    static func approvedEndpoint(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == "apple.com" || host.hasSuffix(".apple.com"),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443
        else { try ensureFailed("Authentication requires an Apple HTTPS endpoint.") }
        return url
    }

    private static func createInitialRequestEndpoint(baseURL: URL, deviceIdentifier: String) throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            try ensureFailed("\(Strings.invalidAuthEndpoint): \(baseURL)")
        }
        var query = comps.queryItems ?? []
        query.removeAll { $0.name == "guid" }
        query.append(URLQueryItem(name: "guid", value: deviceIdentifier))
        comps.queryItems = query
        return try approvedEndpoint(comps.url.get())
    }

    /// - Parameters:
    ///   - attempt: attested sign-in counts attempts like ipatool; `nil` keeps the previous `4`/`2` values.
    ///   - extraHeaders: machine identity or Store proof headers, sent before cookies and the signature.
    static func makeRequest(
        endpoint: URL, email: String, password: String, code: String, cookies: [Cookie], deviceIdentifier: String,
        sapSigner: any SAPRequestSigning, attempt: String? = nil, userAgent: String = Configuration.userAgent,
        extraHeaders: [(String, String)] = [],
    ) async throws -> HTTPClient.Request {
        let parameters: [String: String] = [
            "appleId": email, "attempt": attempt ?? "\(code.isEmpty ? "4" : "2")", "guid": deviceIdentifier, "password": "\(password)\(code)",
            "rmp": "0", "why": "signIn",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
        var headers: [(String, String)] = [("User-Agent", userAgent), ("Content-Type", "application/x-apple-plist")]
        headers.append(contentsOf: extraHeaders)
        for item in cookies.buildCookieHeader(endpoint) {
            headers.append(item)
        }
        _ = try approvedEndpoint(endpoint)
        let signature = try await sapSigner.sign(data)
        headers.append(("X-Apple-ActionSignature", signature.base64EncodedString()))
        APLogger.logRequest(method: "POST", url: endpoint.absoluteString, headers: headers)
        return try .init(url: endpoint.absoluteString, method: .POST, headers: .init(headers), body: .data(data))
    }

    /// Attested sign-in may omit `dsPersonId`; Apple still sends the DSID as `X-Dsid` or in
    /// `mz_at0-<DSID>` / `mz_at_ssl-<DSID>` cookie names.
    static func responseDSID(_ headers: HTTPHeaders) -> String? {
        if let value = headers.first(name: "X-Dsid")?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            return value
        }
        let pattern = try? NSRegularExpression(pattern: "(?:^|[ ,])mz_at(?:0|_ssl)-([0-9]+)=")
        for value in headers["Set-Cookie"] {
            let range = NSRange(value.startIndex ..< value.endIndex, in: value)
            if let match = pattern?.firstMatch(in: value, range: range), let dsid = Range(match.range(at: 1), in: value) {
                return String(value[dsid])
            }
        }
        return nil
    }

    private func parseResponse(_ response: HTTPClient.Response, email: String, password: String, code: String) throws -> LoginResponse {
        APLogger.logResponse(
            status: response.status.code, headers: response.headers.map { ($0.name, $0.value) }, bodySize: response.body?.readableBytes,
        )

        cookies.mergeCookies(response.cookies)

        let readStoreFrontValue = response.headers["x-set-apple-store-front"].filter { !$0.isEmpty }.compactMap {
            $0.components(separatedBy: "-").first
        }.filter { !$0.isEmpty }
        assert(readStoreFrontValue.count <= 1)
        if let first = readStoreFrontValue.first {
            storeFront = first
        }

        if let podValue = response.headers.first(name: "pod"), !podValue.isEmpty {
            pod = podValue
        }

        let redirectStatuses: [HTTPResponseStatus] = [.movedPermanently, .found, .seeOther, .temporaryRedirect, .permanentRedirect]
        if redirectStatuses.contains(response.status) {
            guard let location = response.headers.first(name: "location"), let url = URL(string: location) else {
                return .failure(Strings.failedToRetrieveRedirect)
            }
            return .redirect(url)
        }

        guard response.status == .ok else { return .failure("HTTP \(response.status.code)") }
        guard var body = response.body, body.readableBytes <= 2 * 1024 * 1024, let data = body.readData(length: body.readableBytes) else {
            return .failure("response body is empty (code: \(response.status.code))")
        }

        let listItem = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dic = try (listItem as? [String: Any]).get(Strings.responseNotDictionary)

        if let failureType = dic["failureType"] as? String, failureType.isEmpty, code.isEmpty,
           let customerMessage = dic["customerMessage"] as? String, customerMessage == "MZFinance.BadLogin.Configurator_message"
        {
            return .codeRequired
        }

        if let failureType = dic["failureType"] as? String, failureType == "-5000" {
            return .retry
        }

        if let failureType = dic["failureType"] as? String, failureType == "5005" {
            return .failure(Strings.invalid2FACode)
        }

        let failureMessage = (dic["dialog"] as? [String: Any])?["explanation"] as? String ?? (dic["customerMessage"] as? String)
        let accountInfoDic = try (dic["accountInfo"] as? [String: Any]).get(failureMessage ?? Strings.missingAccountInfo)
        let addressInfoDic = try (accountInfoDic["address"] as? [String: Any]).get(failureMessage ?? Strings.missingAddress)
        let directoryServicesIdentifier = (dic["dsPersonId"] as? String)
            ?? (dic["dsPersonId"] as? NSNumber)?.stringValue
            ?? Self.responseDSID(response.headers)

        let account = try Account(
            email: email, password: password, appleId: accountInfoDic["appleId"] as? String, store: storeFront,
            firstName: addressInfoDic["firstName"] as? String, lastName: addressInfoDic["lastName"] as? String,
            passwordToken: dic["passwordToken"] as? String, directoryServicesIdentifier: directoryServicesIdentifier, cookie: cookies,
            pod: pod,
        )
        return .success(account)
    }
}
