//
//  RemoteAttestationProvider.swift
//  Asspp
//
//  Created on 2026/11/11.
//

import ApplePackage
import Foundation

/// Device attestation from an asspp-attestd service (Tools/attestd), on this Mac or the LAN.
/// Configure with:
///   defaults write wiki.qaq.Asspp AttestationServiceURL http://127.0.0.1:18765
///   defaults write wiki.qaq.Asspp AttestationServiceToken <token>
struct RemoteAttestationProvider: DeviceAttestationProviding {
    static let urlKey = "AttestationServiceURL"
    static let tokenKey = "AttestationServiceToken"

    let baseURL: URL
    let token: String

    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> RemoteAttestationProvider? {
        guard let raw = defaults.string(forKey: urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme == "http" || url.scheme == "https", url.host != nil,
              let token = defaults.string(forKey: tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return nil }
        return RemoteAttestationProvider(baseURL: url, token: token)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // First use prepares Apple's components; each emulator call takes a few seconds.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func machineHeaders(deviceIdentifier: String) async throws -> [String: String] {
        let response: HeadersResponse = try await post("v1/machine-headers", GUIDRequest(guid: deviceIdentifier))
        return response.headers
    }

    func provisionStore(_ request: StoreProvisioningRequest) async throws -> StoreProvisioningResult {
        let response: CookiesResponse = try await post("v1/provision", ProvisionRequest(
            guid: request.deviceIdentifier, challenge: request.challenge, endpoint: request.endpoint.absoluteString,
            userAgent: request.userAgent, machineHeaders: request.machineHeaders, cookies: request.cookies,
        ))
        return StoreProvisioningResult(cookies: response.cookies)
    }

    func storeHeaders(deviceIdentifier: String, url: URL) async throws -> [String: String] {
        let response: HeadersResponse = try await post("v1/store-headers", StoreHeadersRequest(guid: deviceIdentifier, url: url.absoluteString))
        return response.headers
    }

    func keybagSync(deviceIdentifier: String, dsid: UInt64) async throws -> Data {
        let response: KBSyncResponse = try await post("v1/kbsync", KBSyncRequest(guid: deviceIdentifier, dsid: String(dsid)))
        guard let data = Data(base64Encoded: response.kbsync), !data.isEmpty else {
            throw DeviceAttestationError.failed("the service returned invalid kbsync data")
        }
        return data
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, _ body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DeviceAttestationError.unavailable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let detail = "\(failure?.code ?? "HTTP \(status)"): \(failure?.message ?? "no details")"
            switch failure?.code {
            case "not_provisioned": throw DeviceAttestationError.notProvisioned
            case "unauthorized", "assets_unavailable": throw DeviceAttestationError.unavailable(detail)
            case "canceled": throw CancellationError()
            default: throw DeviceAttestationError.failed(detail)
            }
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DeviceAttestationError.failed("unexpected response from \(path)")
        }
    }
}

private struct GUIDRequest: Encodable {
    let guid: String
}

private struct StoreHeadersRequest: Encodable {
    let guid: String
    let url: String
}

private struct KBSyncRequest: Encodable {
    let guid: String
    let dsid: String
}

private struct ProvisionRequest: Encodable {
    let guid: String
    let challenge: String
    let endpoint: String
    let userAgent: String
    let machineHeaders: [String: String]
    let cookies: [Cookie]
}

private struct HeadersResponse: Decodable {
    let headers: [String: String]
}

private struct CookiesResponse: Decodable {
    let cookies: [Cookie]
}

private struct KBSyncResponse: Decodable {
    let kbsync: String
}

private struct ErrorResponse: Decodable {
    let code: String
    let message: String
}
