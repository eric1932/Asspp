//
//  EmbeddedAttestationRuntime.swift
//  AssppEmbeddedAttestation
//
//  Created on 2026/11/11.
//

import Foundation

#if canImport(AssppAttest)
    import AssppAttest
#endif

/// asspp-attestd running inside the app (Tools/attestd/embedded).
///
/// The same methods and JSON bodies as the HTTP service, without a listener or
/// a token. Only present when AssppAttest.xcframework was linked in; otherwise
/// `isAvailable` is false and every call throws `RuntimeError.unavailable`.
public enum EmbeddedAttestationRuntime {
    public struct Response: Sendable {
        /// 200 on success, otherwise the HTTP status the service would have sent.
        public let status: Int
        public let body: Data
    }

    public enum RuntimeError: Error {
        case unavailable
        case configurationFailed
    }

    public static var isAvailable: Bool {
        #if canImport(AssppAttest)
            true
        #else
            false
        #endif
    }

    /// Sets the directory that holds one state file per device. Call once before `call`.
    public static func configure(stateDirectory: URL) throws {
        #if canImport(AssppAttest)
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            guard asb_configure(stateDirectory.path) == 0 else { throw RuntimeError.configurationFailed }
        #else
            throw RuntimeError.unavailable
        #endif
    }

    /// Runs one method ("machine-headers", "kbsync", ...) with its JSON body.
    /// Calls take seconds, or minutes the first time while Apple's components are
    /// downloaded. They run off the cooperative thread pool and honor task cancellation.
    public static func call(_ method: String, body: Data) async throws -> Response {
        #if canImport(AssppAttest)
            let token = tokens.next()
            let canceled = Flag()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                    queue.async {
                        if canceled.isSet {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        var response: UnsafeMutablePointer<UInt8>?
                        var length: UInt64 = 0
                        let status = body.withUnsafeBytes { bytes in
                            asb_call(method, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), token, &response, &length)
                        }
                        let data = response.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                        asb_free(UnsafeMutableRawPointer(response))
                        continuation.resume(returning: Response(status: status == 0 ? 200 : Int(status), body: data))
                    }
                }
            } onCancel: {
                canceled.set()
                asb_cancel(token)
            }
        #else
            throw RuntimeError.unavailable
        #endif
    }

    #if canImport(AssppAttest)
        /// One emulator operation runs at a time, so one serial queue is enough.
        private static let queue = DispatchQueue(label: "wiki.qaq.asspp.attest.embedded", qos: .userInitiated)
        private static let tokens = TokenSource()
    #endif
}

#if canImport(AssppAttest)
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private final class TokenSource: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64 = 0

        /// A non-zero token, unique for the life of the process.
        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            last += 1
            return last
        }
    }
#endif
