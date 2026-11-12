//
//  HTTPAttestationTransport.swift
//  Asspp
//
//  Created on 2026/11/11.
//

import ApplePackage
import Foundation

/// Reaches an asspp-attestd service on this Mac or the LAN. Configure with:
///   defaults write wiki.qaq.Asspp AttestationServiceURL http://127.0.0.1:18765
///   defaults write wiki.qaq.Asspp AttestationServiceToken <token>
struct HTTPAttestationTransport: AttestationServiceTransport {
    static let urlKey = "AttestationServiceURL"
    static let tokenKey = "AttestationServiceToken"

    let baseURL: URL
    let token: String

    var summary: String { "service at \(baseURL.absoluteString)" }

    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> HTTPAttestationTransport? {
        guard let raw = defaults.string(forKey: urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme == "http" || url.scheme == "https", url.host != nil,
              let token = defaults.string(forKey: tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return nil }
        return HTTPAttestationTransport(baseURL: url, token: token)
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

    func send(_ method: String, body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        do {
            let (data, response) = try await Self.session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DeviceAttestationError.unavailable(error.localizedDescription)
        }
    }
}
