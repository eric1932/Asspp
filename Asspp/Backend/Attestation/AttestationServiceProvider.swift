//
//  AttestationServiceProvider.swift
//  Asspp
//
//  Created on 2026/11/11.
//

import ApplePackage
import Foundation

/// Where an asspp-attestd call goes: over HTTP to a service, or into the runtime linked into the app.
protocol AttestationServiceTransport: Sendable {
    /// One phrase for the log, without secrets.
    var summary: String { get }

    /// Sends `body` to `method`, the API path after `v1/`, and returns the HTTP status and body.
    /// Throws `CancellationError` when canceled, and `DeviceAttestationError.unavailable`
    /// when the service cannot be reached.
    func send(_ method: String, body: Data) async throws -> (status: Int, body: Data)
}

/// Device attestation from asspp-attestd (Tools/attestd), reached through a transport.
struct AttestationServiceProvider: DeviceAttestationProviding {
    let transport: any AttestationServiceTransport

    func machineHeaders(deviceIdentifier: String) async throws -> [String: String] {
        let response: HeadersResponse = try await post("machine-headers", GUIDRequest(guid: deviceIdentifier))
        return response.headers
    }

    func provisionStore(_ request: StoreProvisioningRequest) async throws -> StoreProvisioningResult {
        let response: CookiesResponse = try await post("provision", ProvisionRequest(
            guid: request.deviceIdentifier, challenge: request.challenge, endpoint: request.endpoint.absoluteString,
            userAgent: request.userAgent, machineHeaders: request.machineHeaders, cookies: request.cookies,
        ))
        return StoreProvisioningResult(cookies: response.cookies)
    }

    func storeHeaders(deviceIdentifier: String, url: URL) async throws -> [String: String] {
        let response: HeadersResponse = try await post("store-headers", StoreHeadersRequest(guid: deviceIdentifier, url: url.absoluteString))
        return response.headers
    }

    func keybagSync(deviceIdentifier: String, dsid: UInt64) async throws -> Data {
        let response: KBSyncResponse = try await post("kbsync", KBSyncRequest(guid: deviceIdentifier, dsid: String(dsid)))
        guard let data = Data(base64Encoded: response.kbsync), !data.isEmpty else {
            throw DeviceAttestationError.failed("the service returned invalid kbsync data")
        }
        return data
    }

    private func post<Response: Decodable>(_ method: String, _ body: some Encodable) async throws -> Response {
        let (status, data) = try await transport.send(method, body: JSONEncoder().encode(body))

        guard status == 200 else {
            let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let detail = "\(failure?.code ?? "HTTP \(status)"): \(failure?.message ?? "no details")"
            switch failure?.code {
            case "not_provisioned": throw DeviceAttestationError.notProvisioned
            case "unauthorized", "assets_unavailable", "not_configured": throw DeviceAttestationError.unavailable(detail)
            case "canceled": throw CancellationError()
            default: throw DeviceAttestationError.failed(detail)
            }
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DeviceAttestationError.failed("unexpected response from \(method)")
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
