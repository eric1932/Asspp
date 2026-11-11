//
//  Bag.swift
//  ApplePackage
//
//  Created on 2026/2/20.
//

import AsyncHTTPClient
import Foundation

public enum Bag {
    public struct BagOutput {
        public var authEndpoint: URL
        public var redownloadEndpoint: URL?
        public var updateEndpoint: URL?
    }

    private static let defaultAuthEndpoint = "https://auth.itunes.apple.com/auth/v1/native/fast/"

    /// Attested sign-in follows ipatool 2.8.0: legacy Store hosts use this path.
    static let attestedLegacyTrailingSlash = true

    /// - Parameter attested: request the bag the way attested sign-in does (`ix=6`, the
    ///   attested user agent) and normalize the endpoint for it.
    public static func fetchBag(
        redirectConfiguration: HTTPClient.Configuration.RedirectConfiguration = .follow(max: 8, allowCycles: false),
        attested: Bool = false,
    ) async throws -> BagOutput {
        let deviceIdentifier = Configuration.deviceIdentifier
        let fallback = attested ? attestedDefaultAuthEndpoint : URL(string: defaultAuthEndpoint)!

        let client = Configuration.makeHTTPClient(redirectConfiguration: redirectConfiguration)
        defer { _ = client.shutdown() }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "init.itunes.apple.com"
        comps.path = "/bag.xml"
        comps.queryItems = attested
            ? [URLQueryItem(name: "ix", value: "6"), URLQueryItem(name: "guid", value: deviceIdentifier)]
            : [URLQueryItem(name: "guid", value: deviceIdentifier)]
        guard let url = comps.url else {
            APLogger.debug("bag: failed to construct URL, using default auth endpoint")
            return BagOutput(authEndpoint: fallback)
        }

        let headers: [(String, String)] = [
            ("User-Agent", attested ? DeviceAttestation.userAgent : Configuration.userAgent),
            ("Accept", "application/xml"),
        ]

        APLogger.logRequest(method: "GET", url: url.absoluteString, headers: headers)

        let request = try HTTPClient.Request(
            url: url.absoluteString,
            method: .GET,
            headers: .init(headers),
        )

        let response = try await client.execute(request: request).get()

        APLogger.logResponse(
            status: response.status.code,
            headers: response.headers.map { ($0.name, $0.value) },
            bodySize: response.body?.readableBytes,
        )

        guard var body = response.body,
              let data = body.readData(length: body.readableBytes)
        else {
            APLogger.debug("bag: empty response body, using default auth endpoint")
            return BagOutput(authEndpoint: fallback)
        }

        return parse(data, attested: attested)
    }

    static var attestedDefaultAuthEndpoint: URL {
        legacyAuthEndpoint(URL(string: "https://buy.itunes.apple.com\(legacyAuthenticatePath)")!, trailingSlash: attestedLegacyTrailingSlash)
    }

    static func parse(_ data: Data, attested: Bool = false) -> BagOutput {
        let plistData = extractPlistData(from: data)
        let fallback = attested ? attestedDefaultAuthEndpoint : URL(string: defaultAuthEndpoint)!

        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil,
            ) as? [String: Any]
        else {
            APLogger.debug("bag: failed to parse plist, using default auth endpoint")
            return BagOutput(authEndpoint: fallback)
        }

        // authenticateAccount used to live inside the nested urlBag dict,
        // newer bag responses move it to the plist root
        let urlBag = plist["urlBag"] as? [String: Any] ?? [:]
        let authURLString = (plist["authenticateAccount"] as? String) ?? (urlBag["authenticateAccount"] as? String)

        let normalizedURL: URL? = if let authURLString {
            attested ? attestedAuthEndpoint(from: authURLString) : normalizedAuthEndpoint(from: authURLString)
        } else {
            nil
        }
        let authURL = normalizedURL ?? fallback
        if authURLString == nil {
            APLogger.debug("bag: no authenticateAccount in plist, using default auth endpoint")
        }

        APLogger.info("bag: auth endpoint resolved to \(APLogger.safeURL(authURL.absoluteString))")
        return BagOutput(
            authEndpoint: authURL,
            redownloadEndpoint: downloadEndpoint(plist["redownloadProduct"] ?? urlBag["redownloadProduct"], path: "/r/redownload"),
            updateEndpoint: downloadEndpoint(plist["updateProduct"] ?? urlBag["updateProduct"], path: "/up/updateProduct"),
        )
    }

    private static func downloadEndpoint(_ value: Any?, path: String) -> URL? {
        guard let value = value as? String, let url = URL(string: value),
              url.scheme == "https", url.host == "downloaddispatch.itunes.apple.com",
              url.path == path, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }

    static let legacyAuthenticatePath = "/WebObjects/MZFinance.woa/wa/authenticate"

    static func isLegacyAuthHost(_ host: String) -> Bool {
        host == "buy.itunes.apple.com" || host.range(of: "^p[0-9]+-buy[.]itunes[.]apple[.]com$", options: .regularExpression) != nil
    }

    /// The bag advertises the native auth endpoint without the `/fast/` sub-path
    /// that the login flow requires; the no-trailing-slash variant 301s to an
    /// HTML page.
    ///
    /// The legacy authenticate route is kept in its bare form, as the bag and
    /// Apple's redirects spell it. Measured on 2026-11-10, Apple's edge passed
    /// the bare path to the store backend for most requests but the
    /// trailing-slash form almost never (204/301/404/503 from the edge itself).
    /// `Authenticator` still tries the slash form on some edge retries.
    static func normalizedAuthEndpoint(from urlString: String) -> URL? {
        guard var comps = URLComponents(string: urlString) else { return nil }
        if comps.host == "auth.itunes.apple.com" {
            var path = comps.path
            while path.hasSuffix("/") {
                path.removeLast()
            }
            if !path.hasSuffix("/fast") {
                path += "/fast"
            }
            comps.path = path + "/"
        } else if comps.scheme?.lowercased() == "https", let host = comps.host?.lowercased(), isLegacyAuthHost(host) {
            var path = comps.path
            while path.hasSuffix("/") {
                path.removeLast()
            }
            if path == legacyAuthenticatePath {
                comps.path = path
            }
        }
        return comps.url
    }

    /// The legacy authenticate URL with or without its trailing slash; any other URL is returned unchanged.
    static func legacyAuthEndpoint(_ url: URL, trailingSlash: Bool) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true), comps.scheme?.lowercased() == "https",
              let host = comps.host?.lowercased(), isLegacyAuthHost(host)
        else { return url }
        var path = comps.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        guard path == legacyAuthenticatePath else { return url }
        comps.path = trailingSlash ? path + "/" : path
        return comps.url ?? url
    }

    /// Attested sign-in normalizes like ipatool 2.8.0: legacy Store hosts always use the
    /// authenticate path (slash per `attestedLegacyTrailingSlash`); other hosts, including
    /// the native `auth.itunes.apple.com` endpoint, are used exactly as advertised.
    static func attestedAuthEndpoint(from urlString: String) -> URL? {
        guard var comps = URLComponents(string: urlString), comps.scheme?.lowercased() == "https" else { return nil }
        if let host = comps.host?.lowercased(), isLegacyAuthHost(host) {
            comps.path = attestedLegacyTrailingSlash ? legacyAuthenticatePath + "/" : legacyAuthenticatePath
        }
        return comps.url
    }

    /// The bag XML response wraps the plist inside `<Document><Protocol><plist>...</plist>`.
    /// Extract the `<plist>...</plist>` portion so PropertyListSerialization can parse it.
    /// If the data is already a bare plist, return it as-is.
    private static func extractPlistData(from data: Data) -> Data {
        guard let xmlString = String(data: data, encoding: .utf8),
              let startRange = xmlString.range(of: "<plist"),
              let endRange = xmlString.range(of: "</plist>")
        else {
            return data
        }
        return Data(xmlString[startRange.lowerBound ..< endRange.upperBound].utf8)
    }
}
