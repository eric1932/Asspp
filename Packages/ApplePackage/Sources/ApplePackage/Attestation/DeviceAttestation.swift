//
//  DeviceAttestation.swift
//  ApplePackage
//
//  Created on 2026/11/11.
//

import Foundation

/// Supplies the device attestation Apple's Store requires since November 2026:
/// machine (anisette) headers, Store provisioning, and per-request Store AMD proof.
///
/// ApplePackage ships no implementation. An implementation may run elsewhere
/// (for example a local or LAN service), or a native algorithm may adopt it later.
/// Methods can take seconds (minutes on first use) and must honor Task cancellation.
/// Implementations own and persist their state, and must tolerate concurrent calls.
public protocol DeviceAttestationProviding: Sendable {
    /// Machine identity headers (`X-Apple-I-MD`, `X-Apple-I-MD-M`, `X-Apple-I-MD-RINFO`,
    /// `X-Mme-Device-Id`, ...). Re-provisions the machine and discards any Store provisioning,
    /// so it is only used when no Store proof is available.
    func machineHeaders(deviceIdentifier: String) async throws -> [String: String]

    /// Completes Store provisioning with the challenge Apple sent in `X-Apple-AMD-Data`.
    func provisionStore(_ request: StoreProvisioningRequest) async throws -> StoreProvisioningResult

    /// Store AMD proof (`X-Apple-AMD`, `X-Apple-AMD-M`) for an exact request URL.
    /// Throws `DeviceAttestationError.notProvisioned` before Store provisioning completed.
    func storeHeaders(deviceIdentifier: String, url: URL) async throws -> [String: String]

    /// Keybag sync data for entitlement downloads.
    func keybagSync(deviceIdentifier: String, dsid: UInt64) async throws -> Data
}

public extension DeviceAttestationProviding {
    func keybagSync(deviceIdentifier _: String, dsid _: UInt64) async throws -> Data {
        throw DeviceAttestationError.unsupported
    }
}

public struct StoreProvisioningRequest: Sendable {
    public var deviceIdentifier: String
    public var challenge: String
    public var endpoint: URL
    public var userAgent: String
    public var machineHeaders: [String: String]
    public var cookies: [Cookie]

    public init(
        deviceIdentifier: String, challenge: String, endpoint: URL, userAgent: String, machineHeaders: [String: String], cookies: [Cookie],
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.challenge = challenge
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.machineHeaders = machineHeaders
        self.cookies = cookies
    }
}

public struct StoreProvisioningResult: Sendable {
    /// Cookies Apple set while finishing provisioning; merged into the sign-in session.
    public var cookies: [Cookie]

    public init(cookies: [Cookie] = []) {
        self.cookies = cookies
    }
}

public enum DeviceAttestationError: LocalizedError, Sendable {
    case notProvisioned
    case unsupported
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notProvisioned: "This device has not completed Apple Store provisioning yet."
        case .unsupported: "The device attestation provider does not support this operation."
        case let .unavailable(message): "The device attestation provider is unavailable: \(message)"
        case let .failed(message): "Device attestation failed: \(message)"
        }
    }
}

public enum DeviceAttestation {
    /// Store provisioning endpoint used after Apple answers `X-Apple-AMD-Action: SP`.
    public static let storeProvisioningEndpoint = URL(string: "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish")!

    /// The Configurator identity attested sign-in uses (matches ipatool 2.8.0).
    public static let userAgent = "Configurator/2.21 (Macintosh; OS X 27.0.1; 26A434) AppleWebKit/0625.2.5.11.6"

    static let entDownloadPath = "/WebObjects/DownloadDispatch.woa/wa/ent/download"
    static let commerceDispatchPaths: Set<String> = [entDownloadPath, "/r/redownload", "/up/updateProduct"]
    static let volumeStorePath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

    /// Store AMD proof for a download request when a provider is configured and the URL is
    /// one Apple expects it on; otherwise no headers.
    public static func storeHeaders(for url: URL) async throws -> [String: String] {
        guard let provider = Configuration.deviceAttestationProvider, isCommerceURL(url) else { return [:] }
        return try await provider.storeHeaders(deviceIdentifier: Configuration.deviceIdentifier, url: url)
    }

    /// Download URLs that carry Store AMD proof: https, default port, no fragment or encoded
    /// path, and exactly one non-empty `guid` query item.
    static func isCommerceURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              components.percentEncodedPath == components.path,
              let host = components.host?.lowercased(),
              let items = components.queryItems, items.count == 1, items[0].name == "guid", let guid = items[0].value, !guid.isEmpty
        else { return false }
        if host == "downloaddispatch.itunes.apple.com" {
            return commerceDispatchPaths.contains(components.path)
        }
        return Bag.isLegacyAuthHost(host) && components.path == volumeStorePath
    }

    /// Headers for an authentication request: machine `X-Apple-I-MD` / `X-Apple-I-MD-M`
    /// travel as `X-Apple-AMD` / `X-Apple-AMD-M`; everything else is sent unchanged.
    static func loginHeaders(_ headers: [String: String]) -> [(String, String)] {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.compactMap { key, value -> (String, String)? in
            switch key.lowercased() {
            case "x-apple-i-md": return value.isEmpty ? nil : ("X-Apple-AMD", value)
            case "x-apple-i-md-m": return value.isEmpty ? nil : ("X-Apple-AMD-M", value)
            default: return (key, value)
            }
        }
    }

    /// Apple answers `X-Apple-AMD-Action: RP` by asking for a request without machine identity.
    static func removingMachineIdentity(_ headers: [String: String]) -> [String: String] {
        let removed: Set<String> = ["x-apple-i-md", "x-apple-i-md-m", "x-apple-i-md-rinfo"]
        return headers.filter { !removed.contains($0.key.lowercased()) }
    }

    static func isHardwareIdentifier(_ value: String) -> Bool {
        value.count == 12 && value.allSatisfy(\.isHexDigit)
    }
}
