import Foundation

enum StoreDownloadError: LocalizedError {
    case invalidRedirect
    case response(Int)
    case emptyResponse(Int)
    case invalidPackage
    case empty
    case catalogUnavailable
    case actionRequired
    case noVersions
    case rejected(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidRedirect:
            String(localized: "Apple returned an invalid download redirect.")
        case let .response(status), let .emptyResponse(status):
            String(localized: "Apple's download service returned an invalid response (HTTP \(status)).")
        case .invalidPackage:
            String(localized: "Apple returned incomplete or mismatched package information.")
        case .empty:
            String(localized: "Apple returned no downloadable package from either download service. This does not mean the app does not exist. Check this account's license, store region, and the requested version. See Settings > Logs for details.")
        case .catalogUnavailable:
            String(localized: "Unable to determine the current version for this platform. Try again later or select a specific historical version.")
        case .actionRequired:
            String(localized: "Apple requires an account confirmation. Open the App Store with this account, complete any prompts, then try again.")
        case .noVersions:
            String(localized: "Apple returned no version history for this app and platform.")
        case let .rejected(code, message):
            message.isEmpty ? String(localized: "Apple rejected the download (code: \(code)).") : message
        }
    }
}

/// Response classification and request rules without credentials or networking.
enum StoreDownloadProtocol {
    static func isMainInfoPlist(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3 && components[0] == "Payload"
            && components[1].hasSuffix(".app") && components[2] == "Info.plist"
    }

    static func validatePackageInfo(_ info: [String: Any], bundleID: String, platform: String) throws {
        let platforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
        let platformName = info["DTPlatformName"] as? String ?? ""
        guard info["CFBundleIdentifier"] as? String == bundleID,
              platforms.contains(platform) || platformName.lowercased() == platform.lowercased()
        else { throw StoreDownloadError.invalidPackage }
    }

    struct CatalogVersion {
        let bundleID: String?
        let externalVersionID: String
    }

    static func catalogVersion(_ data: Data, appID: Int64) throws -> CatalogVersion {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let item = results[String(appID)] as? [String: Any],
              let offers = item["offers"] as? [[String: Any]]
        else { throw StoreDownloadError.catalogUnavailable }
        for offer in offers {
            let version = offer["version"] as? [String: Any]
            var identifier = StoreProtocol.string(version?["externalId"])
            if identifier.isEmpty, let parameters = offer["buyParams"] as? String {
                let components = URLComponents(string: "?" + parameters)
                identifier = components?.queryItems?.first { $0.name == "appExtVrsId" }?.value ?? ""
            }
            if !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return CatalogVersion(bundleID: item["bundleId"] as? String, externalVersionID: identifier)
            }
        }
        throw StoreDownloadError.catalogUnavailable
    }

    enum Endpoint: String {
        case volumeStore, redownload, update

        var versionKey: String {
            self == .volumeStore ? "externalVersionId" : "appExtVrsId"
        }

        var path: String {
            switch self {
            case .volumeStore: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
            case .redownload: "/r/redownload"
            case .update: "/up/updateProduct"
            }
        }
    }

    static func validatedURL(_ url: URL) throws -> URL {
        let host = url.host?.lowercased() ?? ""
        let storeHost = host == "buy.itunes.apple.com"
            || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
        let storePath = [Endpoint.volumeStore.path, "/WebObjects/MZFinance.woa/wa/redownloadProduct"].contains(url.path)
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              (storeHost && storePath) || (host == "downloaddispatch.itunes.apple.com"
                  && [Endpoint.redownload.path, Endpoint.update.path].contains(url.path))
        else { throw StoreDownloadError.invalidRedirect }
        return url
    }

    static let entDownloadPath = "/WebObjects/DownloadDispatch.woa/wa/ent/download"

    /// The six bytes of a 12-hex-digit device GUID.
    static func hardwareID(_ guid: String) -> [UInt8]? {
        let digits = Array(guid.utf8)
        guard digits.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(decoding: digits[index ..< index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }

    /// ent/download body as ipatool 2.8.0 builds it: string adam ID, base64 kbsync, and a
    /// serial number of a fixed prefix followed by the last four GUID bytes.
    static func entPayload(appID: Int64, guid: String, kbsync: Data, hardwareID: [UInt8], version: String) -> [String: Any] {
        var serialBytes: [UInt8] = [0x54, 0xC8, 0xB0, 0xA9, 0x88]
        serialBytes.append(contentsOf: hardwareID.dropFirst(2))
        let serial = Data(serialBytes)
        var result: [String: Any] = [
            "creditDisplay": "", "guid": guid, "kbsync": kbsync.base64EncodedString(),
            "salableAdamId": String(appID), "serialNumber": serial.base64EncodedString(),
        ]
        if !version.isEmpty {
            result["externalVersionId"] = version
        }
        return result
    }

    static func payload(endpoint: Endpoint, appID: Int64, guid: String, version: String?) -> [String: Any] {
        var result: [String: Any] = ["creditDisplay": "", "guid": guid, "salableAdamId": appID, "serialNumber": "0"]
        if let version, !version.isEmpty {
            result[endpoint.versionKey] = version
        }
        return result
    }

    static func failureCode(_ response: [String: Any]) -> String {
        let failure = StoreProtocol.string(response["failureType"])
        if !failure.isEmpty {
            return failure
        }
        let metrics = response["metrics"] as? [String: Any]
        let code = StoreProtocol.string(metrics?["messageCode"])
        return code == "0" ? "" : code
    }

    static func fallbackReason(_ response: [String: Any]) -> String? {
        let failure = failureCode(response)
        if failure == "5002" {
            return "failure-5002"
        }
        guard failure.isEmpty,
              StoreProtocol.string(response["customerMessage"]).isEmpty,
              response["dialog"] == nil, response["action"] == nil
        else { return nil }
        let status = StoreProtocol.string(response["status"])
        guard status.isEmpty || status == "0" else { return nil }
        if let items = response["songList"] as? [Any] {
            return items.isEmpty ? "empty-songList" : nil
        }
        return response["songList"] == nil ? "missing-songList" : nil
    }

    /// Each endpoint is attempted at most once. A failed catalog lookup must not turn into an
    /// unpinned redownload, and historical requests must keep their version ID.
    static func fetchWithFallback(
        version: String?,
        fetch: (Endpoint, String?) async throws -> [String: Any],
        resolveVersion: () async throws -> String,
        onFallback: (String) -> Void,
    ) async throws -> [String: Any] {
        let primary = try await fetch(.volumeStore, version)
        guard let reason = fallbackReason(primary) else { return primary }
        onFallback(reason)
        let resolved: String = if let version, !version.isEmpty {
            version
        } else {
            try await resolveVersion()
        }
        guard !resolved.isEmpty else { throw StoreDownloadError.catalogUnavailable }
        do {
            return try await fetch(.redownload, resolved)
        } catch StoreDownloadError.emptyResponse(500) {
            onFallback("empty-redownload-http500")
            return try await fetch(.update, resolved)
        }
    }

    /// Field names, value kinds and match flags of the returned package items, for
    /// diagnosing `invalidPackage`. No values: metadata carries the Apple ID.
    static func shape(_ response: [String: Any], bundleID: String, version: String?) -> String {
        guard let items = response["songList"] as? [[String: Any]] else {
            return "songList=\(valueKind(response["songList"]))"
        }
        var described: [String] = []
        for (index, item) in items.enumerated() {
            var parts: [String] = ["item\(index) keys=\(item.keys.sorted().joined(separator: ","))"]
            if let text = item["URL"] as? String, let url = URL(string: text) {
                parts.append("URL=\(url.scheme ?? "nil")://\(url.host ?? "nil")")
            } else {
                parts.append("URL=\(valueKind(item["URL"]))")
            }
            parts.append("metadata=\(valueKind(item["metadata"]))")
            if let metadata = item["metadata"] as? [String: Any] {
                for key in ["bundleShortVersionString", "bundleVersion", "softwareVersionBundleId", "softwareVersionExternalIdentifier"] {
                    parts.append("\(key)=\(valueKind(metadata[key]))")
                }
                let returnedBundle = metadata["softwareVersionBundleId"] as? String
                parts.append("bundleMatch=\(returnedBundle == bundleID)")
                if let version {
                    let returnedVersion = StoreProtocol.string(metadata["softwareVersionExternalIdentifier"])
                    parts.append("versionMatch=\(returnedVersion == version)")
                }
            }
            if let sinfs = item["sinfs"] as? [[String: Any]] {
                var entries: [String] = []
                for sinf in sinfs {
                    var fields: [String] = []
                    for key in sinf.keys.sorted() {
                        fields.append("\(key):\(valueKind(sinf[key]))")
                    }
                    let idIsInt64 = (sinf["id"] as? Int64) != nil
                    entries.append("{\(fields.joined(separator: " ")) idInt64=\(idIsInt64)}")
                }
                parts.append("sinfs=\(entries.joined(separator: ","))")
            } else {
                parts.append("sinfs=\(valueKind(item["sinfs"]))")
            }
            described.append(parts.joined(separator: " "))
        }
        return described.joined(separator: " | ")
    }

    private static func valueKind(_ value: Any?) -> String {
        guard let value else { return "missing" }
        if let text = value as? String { return "string(\(text.count))" }
        if let data = value as? Data { return "data(\(data.count))" }
        if let list = value as? [Any] { return "array(\(list.count))" }
        if let dictionary = value as? [String: Any] { return "dict(\(dictionary.count))" }
        if value is NSNumber { return "number" }
        return "other"
    }

    /// Only structural fields and numeric codes are logged. Apple messages can
    /// contain account information; display those to the user, never dump them.
    static func summary(_ response: [String: Any]) -> String {
        func numeric(_ value: Any?) -> String {
            let text = StoreProtocol.string(value)
            if text.isEmpty {
                return "none"
            }
            return text.count <= 12 && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-") } ? text : "other"
        }
        let items: String = if let list = response["songList"] as? [Any] {
            String(list.count)
        } else {
            response["songList"] == nil ? "missing" : "invalid"
        }
        let message = !StoreProtocol.string(response["customerMessage"]).isEmpty
        return "songList=\(items) failure=\(numeric(failureCode(response))) status=\(numeric(response["status"])) customerMessage=\(message) dialog=\(response["dialog"] != nil) action=\(response["action"] != nil)"
    }

    static func packageItem(_ response: [String: Any], bundleID: String, version: String? = nil) throws -> [String: Any] {
        let code = failureCode(response)
        let message = StoreProtocol.string(response["customerMessage"])
        if !code.isEmpty {
            throw StoreDownloadError.rejected(code, message)
        }
        guard let items = response["songList"] as? [[String: Any]], !items.isEmpty else {
            if !message.isEmpty {
                throw StoreDownloadError.rejected("", message)
            }
            if response["dialog"] != nil || response["action"] != nil {
                throw StoreDownloadError.actionRequired
            }
            let status = StoreProtocol.string(response["status"])
            if !status.isEmpty, status != "0" {
                throw StoreDownloadError.rejected(status, "")
            }
            if response["songList"] != nil, !(response["songList"] is [[String: Any]]) {
                throw StoreDownloadError.invalidPackage
            }
            throw StoreDownloadError.empty
        }
        guard let item = items.first(where: {
            ($0["metadata"] as? [String: Any])?["softwareVersionBundleId"] as? String == bundleID
        }) ?? (items.count == 1 ? items.first : nil),
            let metadata = item["metadata"] as? [String: Any]
        else { throw StoreDownloadError.invalidPackage }
        if let returnedBundle = metadata["softwareVersionBundleId"] as? String, returnedBundle != bundleID {
            throw StoreDownloadError.invalidPackage
        }
        let returnedVersion = StoreProtocol.string(metadata["softwareVersionExternalIdentifier"])
        if let version, !returnedVersion.isEmpty, returnedVersion != version {
            throw StoreDownloadError.invalidPackage
        }
        return item
    }
}
