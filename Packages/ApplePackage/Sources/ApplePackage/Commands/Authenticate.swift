import Foundation

public enum Authenticator {
    public static func authenticate(
        email: String,
        password: String,
        code: String = "",
        cookies: [Cookie] = [],
        progress: @escaping @Sendable (AuthenticationProgress) -> Void = { _ in }
    ) async throws -> Account {
        let deviceIdentifier = Configuration.deviceIdentifier
        _ = try AuthenticationValidation.hardwareIdentifier(deviceIdentifier)
        return try await authenticate(email: email, password: password, code: code, cookies: cookies, environment: AuthenticationEnvironment(
            deviceIdentifier: deviceIdentifier,
            userAgent: Configuration.userAgent,
            transport: LiveAuthenticationTransport(),
            makeSigner: { try await LocalSAPSigner.prepare(configuration: $0, hardware: $1, transport: $2, userAgent: $3, progress: $4) },
            progress: progress
        ))
    }

    public static func rotatePasswordToken(for account: inout Account) async throws {
        account = try await authenticate(email: account.email, password: account.password, cookies: account.cookie)
    }

    static func authenticate(email: String, password: String, code: String = "", cookies: [Cookie] = [], environment: AuthenticationEnvironment) async throws -> Account {
        var signer: (any ActionSigner)?
        do {
            try Task.checkCancellation()
            let hardware = try AuthenticationValidation.hardwareIdentifier(environment.deviceIdentifier)
            environment.progress(.loadingConfiguration)
            let bag = try await Bag.fetchBag(transport: environment.transport, deviceIdentifier: environment.deviceIdentifier, userAgent: environment.userAgent)
            let prepared = try await environment.makeSigner(bag.sap, hardware, environment.transport, environment.userAgent, environment.progress)
            signer = prepared
            let result = try await login(email: email, password: password, code: code, cookies: cookies, endpoint: bag.authEndpoint, signer: prepared, environment: environment)
            await prepared.close()
            await environment.transport.close()
            return result
        } catch {
            await signer?.close()
            await environment.transport.close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func login(email: String, password: String, code: String, cookies: [Cookie], endpoint: URL, signer: any ActionSigner, environment: AuthenticationEnvironment) async throws -> Account {
        // Match the pinned ipatool login sequence: start at 1, then allow one
        // follow-up for failureType -5000. That response is not proof of 2FA.
        // Serialize once per attempt; redirects keep exactly the same bytes.
        func requestBody(attempt: Int) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: [
                "appleId": email, "password": password + code.filter { !$0.isWhitespace }, "guid": environment.deviceIdentifier,
                "attempt": String(attempt), "rmp": "0", "why": "signIn",
            ], format: .xml, options: 0)
        }
        var attempt = 1
        var redirects = 0
        var body = try requestBody(attempt: attempt)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "guid" } + [URLQueryItem(name: "guid", value: environment.deviceIdentifier)]
        guard var url = components.url else { throw AuthenticationError.invalidEndpoint }
        var cookies = cookies
        var storeFront = ""
        var pod: String?
        while true {
            try Task.checkCancellation()
            try AuthenticationValidation.authenticationEndpoint(url)
            environment.progress(.signing)
            let signature = try await signer.sign(body)
            guard !signature.isEmpty else { throw AuthenticationError.signingFailed("The signer returned no signature.") }
            try Task.checkCancellation()
            let headers = [
                ("User-Agent", environment.userAgent), ("Content-Type", "application/x-apple-plist"),
                ("X-Apple-ActionSignature", signature.base64EncodedString()),
            ] + cookies.buildCookieHeader(url)
            environment.progress(.authenticating)
            let response = try await environment.transport.send(AuthenticationRequest(url: url, method: "POST", headers: headers, body: body))
            try Task.checkCancellation()
            for cookie in response.cookies {
                cookies.removeAll { $0.name == cookie.name && cookieDomain($0) == cookieDomain(cookie) && $0.path == cookie.path }
                cookies.append(cookie)
            }
            if let value = response.header("x-set-apple-store-front")?.components(separatedBy: "-").first, !value.isEmpty { storeFront = value }
            if let value = response.header("pod"), !value.isEmpty { pod = value }
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard redirects < 3 else { throw AuthenticationError.tooManyRedirects }
                guard let location = response.header("location"), let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw AuthenticationError.invalidEndpoint }
                try AuthenticationValidation.authenticationEndpoint(next)
                url = next
                redirects += 1
                continue
            }
            // In particular, an empty 403 is terminal; retrying the same credentials cannot fix SAP.
            guard response.status == 200 else { throw AuthenticationError.requestRejected(status: response.status) }
            let dictionary = try AuthenticationValidation.plist(response.body)
            if attempt == 1, dictionary["failureType"] as? String == "-5000" {
                attempt = 2
                body = try requestBody(attempt: attempt)
                continue
            }
            return try account(from: dictionary, email: email, password: password, cookies: cookies, storeFront: storeFront, pod: pod)
        }
    }

    private static func cookieDomain(_ cookie: Cookie) -> String? {
        cookie.domain?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func account(from dictionary: [String: Any], email: String, password: String, cookies: [Cookie], storeFront: String, pod: String?) throws -> Account {
        if dictionary["failureType"] as? String == "5005" { throw AuthenticationError.invalidVerificationCode }
        // Verified with fictional credentials: even an empty failureType plus this
        // message is NOT proof of a 2FA challenge. Let the user opt into entering a
        // code they actually received instead of claiming that Apple requires one.
        if dictionary["customerMessage"] as? String == "MZFinance.BadLogin.Configurator_message" {
            throw AuthenticationError.credentialsRejected
        }
        if let failure = dictionary["failureType"] as? String, !failure.isEmpty {
            throw AuthenticationError.serverMessage(dictionary["customerMessage"] as? String ?? Strings.authFailed)
        }
        guard let info = dictionary["accountInfo"] as? [String: Any], let address = info["address"] as? [String: Any] else {
            let message = (dictionary["dialog"] as? [String: Any])?["explanation"] as? String ?? dictionary["customerMessage"] as? String
            throw message.map { AuthenticationError.serverMessage($0) } ?? .invalidResponse
        }
        return try Account(email: email, password: password, appleId: info["appleId"] as? String, store: storeFront,
                           firstName: address["firstName"] as? String, lastName: address["lastName"] as? String,
                           passwordToken: dictionary["passwordToken"] as? String, directoryServicesIdentifier: dictionary["dsPersonId"] as? String,
                           cookie: cookies, pod: pod)
    }
}
