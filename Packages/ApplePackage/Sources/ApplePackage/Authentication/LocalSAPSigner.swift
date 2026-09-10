import Foundation

protocol SAPMachine: ActionSigner {
    func prepare() async throws
    func exchange(version: UInt32, data: Data) async throws -> (data: Data, state: Int32)
}

struct LocalSAPSigner: ActionSigner {
    let machine: any SAPMachine

    static func prepare(configuration: SAPConfiguration, hardware: Data, transport: any AuthenticationTransport, userAgent: String, progress: @escaping AuthenticationEnvironment.Progress) async throws -> any ActionSigner {
        #if canImport(CApplePackageSAP)
        let machine = try await NativeSAPMachine.open(hardware: hardware)
        return try await prepare(machine: machine, configuration: configuration, transport: transport, userAgent: userAgent, progress: progress)
        #else
        throw AuthenticationError.runtimeUnavailable
        #endif
    }

    static func prepare(machine: any SAPMachine, configuration: SAPConfiguration, transport: any AuthenticationTransport, userAgent: String, progress: @escaping AuthenticationEnvironment.Progress = { _ in }) async throws -> LocalSAPSigner {
        do {
            guard configuration.version == 200 else { throw AuthenticationError.unsupportedSAPVersion(configuration.version) }
            try AuthenticationValidation.setupEndpoint(configuration.setupURL, host: "fpinit.itunes.apple.com")
            try AuthenticationValidation.setupEndpoint(configuration.certificateURL, host: "s.mzstatic.com")
            try Task.checkCancellation()
            progress(.preparingResources)
            try await machine.prepare()
            try Task.checkCancellation()
            progress(.preparingSignature)
            let certificateResponse = try await transport.send(AuthenticationRequest(url: configuration.certificateURL, headers: [("User-Agent", userAgent)]))
            let certificate = try payload(certificateResponse, key: "sign-sap-setup-cert")
            let first = try await machine.exchange(version: configuration.version, data: certificate)
            guard first.state == 1, !first.data.isEmpty else { throw AuthenticationError.signingFailed("Unexpected initial SAP handshake state.") }
            try Task.checkCancellation()
            let body = try PropertyListSerialization.data(fromPropertyList: ["sign-sap-setup-buffer": first.data], format: .xml, options: 0)
            let response = try await transport.send(AuthenticationRequest(url: configuration.setupURL, method: "POST", headers: [
                ("User-Agent", userAgent), ("Content-Type", "application/x-apple-plist"),
            ], body: body))
            let next = try payload(response, key: "sign-sap-setup-buffer")
            let final = try await machine.exchange(version: configuration.version, data: next)
            guard final.state == 0 else { throw AuthenticationError.signingFailed("SAP handshake did not complete.") }
            try Task.checkCancellation()
            return LocalSAPSigner(machine: machine)
        } catch {
            await machine.close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func payload(_ response: AuthenticationResponse, key: String) throws -> Data {
        guard response.status == 200 else { throw AuthenticationError.requestRejected(status: response.status) }
        let dictionary = try AuthenticationValidation.plist(response.body)
        guard let data = dictionary[key] as? Data, !data.isEmpty else { throw AuthenticationError.invalidResponse }
        return data
    }

    func sign(_ data: Data) async throws -> Data { try await machine.sign(data) }
    func close() async { await machine.close() }
}
