import Foundation

public enum Bag {
    public struct BagOutput: Sendable {
        public var authEndpoint: URL
        public var sap: SAPConfiguration
    }

    public static func fetchBag() async throws -> BagOutput {
        let transport = LiveAuthenticationTransport()
        do {
            let output = try await fetchBag(transport: transport, deviceIdentifier: Configuration.deviceIdentifier, userAgent: Configuration.userAgent)
            await transport.close()
            return output
        } catch {
            await transport.close()
            throw error
        }
    }

    static func fetchBag(transport: any AuthenticationTransport, deviceIdentifier: String, userAgent: String) async throws -> BagOutput {
        var components = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        components.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        let response = try await transport.send(AuthenticationRequest(url: components.url!, headers: [
            ("User-Agent", userAgent), ("Accept", "application/xml"),
        ]))
        guard response.status == 200 else { throw AuthenticationError.requestRejected(status: response.status) }
        return try parse(response.body)
    }

    static func parse(_ data: Data) throws -> BagOutput {
        let plist = try AuthenticationValidation.plist(extractPlistData(from: data))
        let nested = plist["urlBag"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { plist[key] ?? nested[key] }
        guard let authString = value("authenticateAccount") as? String,
              let endpoint = normalizedAuthEndpoint(from: authString)
        else { throw AuthenticationError.invalidEndpoint }
        try AuthenticationValidation.authenticationEndpoint(endpoint)
        guard let rawVersion = value("sign-sap-version"),
              let version = UInt32(String(describing: rawVersion)),
              let setupString = value("sign-sap-setup") as? String, let setup = URL(string: setupString),
              let certificateString = value("sign-sap-setup-cert") as? String, let certificate = URL(string: certificateString)
        else { throw AuthenticationError.missingSAPConfiguration }
        guard version == 200 else { throw AuthenticationError.unsupportedSAPVersion(version) }
        try AuthenticationValidation.setupEndpoint(setup, host: "fpinit.itunes.apple.com")
        try AuthenticationValidation.setupEndpoint(certificate, host: "s.mzstatic.com")
        return BagOutput(authEndpoint: endpoint, sap: SAPConfiguration(version: version, setupURL: setup, certificateURL: certificate))
    }

    private static func normalizedAuthEndpoint(from string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        if components.host?.lowercased() == "auth.itunes.apple.com" {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == "auth/v1/native" { components.path = "/auth/v1/native/fast/" }
        }
        return components.url
    }

    private static func extractPlistData(from data: Data) -> Data {
        guard let xml = String(data: data, encoding: .utf8),
              let start = xml.range(of: "<plist"),
              let end = xml.range(of: "</plist>", range: start.lowerBound ..< xml.endIndex)
        else { return data }
        return Data(xml[start.lowerBound ..< end.upperBound].utf8)
    }
}
