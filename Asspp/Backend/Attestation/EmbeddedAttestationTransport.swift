//
//  EmbeddedAttestationTransport.swift
//  Asspp
//
//  Created on 2026/11/11.
//

import ApplePackage
import AssppEmbeddedAttestation
import Foundation

/// Computes device attestation inside the app with the embedded asspp-attestd runtime.
/// Only iOS builds that include AssppAttest.xcframework have it.
struct EmbeddedAttestationTransport: AttestationServiceTransport {
    let summary = "the embedded runtime"

    /// Nil when the runtime is not part of this build, or its state directory cannot be set up.
    static func make() -> EmbeddedAttestationTransport? {
        guard EmbeddedAttestationRuntime.isAvailable else { return nil }
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
            )
            try EmbeddedAttestationRuntime.configure(stateDirectory: support.appendingPathComponent("AssppAttest", isDirectory: true))
            return EmbeddedAttestationTransport()
        } catch {
            logger.error("device attestation: embedded runtime setup failed: \(error.localizedDescription)")
            return nil
        }
    }

    func send(_ method: String, body: Data) async throws -> (status: Int, body: Data) {
        do {
            let response = try await EmbeddedAttestationRuntime.call(method, body: body)
            return (response.status, response.body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeviceAttestationError.unavailable("the embedded runtime is not available")
        }
    }
}
