import Foundation

public enum AuthenticationError: Error, LocalizedError, Equatable, Sendable {
    case credentialsRejected
    case invalidVerificationCode
    case requestRejected(status: Int)
    case invalidResponse
    case invalidEndpoint
    case missingSAPConfiguration
    case unsupportedSAPVersion(UInt32)
    case invalidDeviceIdentifier
    case signingFailed(String)
    case runtimeUnavailable
    case tooManyRedirects
    case serverMessage(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsRejected: return "Apple could not verify these credentials. Check your Apple ID and password, or enter a verification code if Apple sent you one."
        case .invalidVerificationCode: return Strings.invalid2FACode
        case .requestRejected(status: 403): return "Apple rejected the request (HTTP 403). Please try again later."
        case let .requestRejected(status): return "Apple returned HTTP \(status)."
        case .invalidResponse: return "Apple returned an invalid or empty authentication response."
        case .invalidEndpoint: return "Apple returned an unsupported authentication endpoint."
        case .missingSAPConfiguration: return "Apple's bag is missing the SAP signing configuration."
        case let .unsupportedSAPVersion(version): return "Unsupported SAP signing version: \(version)."
        case .invalidDeviceIdentifier: return "The device identifier must contain exactly 12 hexadecimal characters."
        case let .signingFailed(message): return "SAP signing failed: \(message)"
        case .runtimeUnavailable: return "This build does not include the SAP signing runtime."
        case .tooManyRedirects: return "Apple returned too many authentication redirects."
        case let .serverMessage(message): return message
        }
    }
}

public enum AuthenticationProgress: Sendable {
    case loadingConfiguration
    case preparingResources
    case preparingSignature
    case signing
    case authenticating
}

public struct SAPConfiguration: Sendable, Equatable {
    public let version: UInt32
    public let setupURL: URL
    public let certificateURL: URL
}

struct AuthenticationRequest: Sendable {
    var url: URL
    var method: String = "GET"
    var headers: [(String, String)] = []
    var body: Data?
}

struct AuthenticationResponse: Sendable {
    var status: Int = 200
    var headers: [(String, String)] = []
    var body: Data = Data()
    var cookies: [Cookie] = []

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

protocol AuthenticationTransport: Sendable {
    func send(_ request: AuthenticationRequest) async throws -> AuthenticationResponse
    func close() async
}

protocol ActionSigner: Sendable {
    func sign(_ data: Data) async throws -> Data
    func close() async
}

struct AuthenticationEnvironment: Sendable {
    typealias Progress = @Sendable (AuthenticationProgress) -> Void
    typealias SignerFactory = @Sendable (SAPConfiguration, Data, any AuthenticationTransport, String, @escaping Progress) async throws -> any ActionSigner

    var deviceIdentifier: String
    var userAgent: String
    var transport: any AuthenticationTransport
    var makeSigner: SignerFactory
    var progress: Progress = { _ in }
}

enum AuthenticationValidation {
    static func hardwareIdentifier(_ guid: String) throws -> Data {
        let bytes = Array(guid.utf8)
        guard bytes.count == 12, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw AuthenticationError.invalidDeviceIdentifier
        }
        return Data(stride(from: 0, to: 12, by: 2).map {
            UInt8(String(decoding: bytes[$0 ..< $0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    static func secureEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.fragment == nil
            && (url.port == nil || url.port == 443)
    }

    static func authenticationEndpoint(_ url: URL) throws {
        guard secureEndpoint(url), let host = url.host?.lowercased() else { throw AuthenticationError.invalidEndpoint }
        let legacy = host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
        let native = host == "auth.itunes.apple.com" && ["/auth/v1/native/", "/auth/v1/native/fast/"].contains(url.path + (url.path.hasSuffix("/") ? "" : "/"))
        guard native || (legacy && url.path == "/WebObjects/MZFinance.woa/wa/authenticate") else {
            throw AuthenticationError.invalidEndpoint
        }
    }

    static func setupEndpoint(_ url: URL, host: String) throws {
        guard secureEndpoint(url), url.host?.lowercased() == host else { throw AuthenticationError.invalidEndpoint }
    }

    static func plist(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any]
        else { throw AuthenticationError.invalidResponse }
        return dictionary
    }
}
