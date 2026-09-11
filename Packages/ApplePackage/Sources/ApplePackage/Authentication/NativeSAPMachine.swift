#if canImport(CApplePackageSAP)
import CApplePackageSAP
import Foundation

// Limit the guest's memory footprint to one active session across accounts.
private actor SAPSessionPermit {
    static let shared = SAPSessionPermit()
    private var occupied = false

    func acquire() async throws {
        while occupied { try await Task.sleep(nanoseconds: 100_000_000) }
        try Task.checkCancellation()
        occupied = true
    }

    func release() { occupied = false }
}

final class NativeSAPMachine: SAPMachine, @unchecked Sendable {
    #if ASSPP_BUNDLED_SAP_ASSETS
    static let usesBundledAssets = true
    #else
    static let usesBundledAssets = false
    #endif
    private let handle: UInt64
    private let queue = DispatchQueue(label: "ApplePackage.SAP", qos: .userInitiated)
    // Accessed only on queue. Native cancellation is independently thread safe.
    private var closed = false

    static func open(hardware: Data) async throws -> NativeSAPMachine {
        try await SAPSessionPermit.shared.acquire()
        do { return try NativeSAPMachine(hardware: hardware) }
        catch {
            await SAPSessionPermit.shared.release()
            throw error
        }
    }

    private init(hardware: Data) throws {
        #if ASSPP_BUNDLED_SAP_ASSETS
        guard let directory = Bundle.module.url(forResource: "SAPAssets", withExtension: "zip") else {
            throw AuthenticationError.signingFailed("Bundled SAP resources are missing. Reinstall this build.")
        }
        #else
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("ApplePackage/SAP/apple-assets-v2", isDirectory: true)
        #endif
        var error: UnsafeMutablePointer<CChar>?
        handle = hardware.withUnsafeBytes { bytes in
            directory.path.withCString { directory in
                #if ASSPP_BUNDLED_SAP_ASSETS
                apsap_create_bundled(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), directory, &error)
                #else
                apsap_create(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), directory, &error)
                #endif
            }
        }
        try Self.check(handle != 0, error: error)
    }

    deinit {
        apsap_close(handle)
        if !closed { Task { await SAPSessionPermit.shared.release() } }
    }

    private static func check(_ success: Bool, error: UnsafeMutablePointer<CChar>?) throws {
        defer { apsap_free(error) }
        guard success else {
            throw AuthenticationError.signingFailed(error.map { String(cString: $0) } ?? "Unknown native error.")
        }
    }

    private func perform<T: Sendable>(_ action: @escaping @Sendable (UInt64) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else {
                        continuation.resume(throwing: AuthenticationError.signingFailed("Session is closed."))
                        return
                    }
                    continuation.resume(with: Result { try action(self.handle) })
                }
            }
        } onCancel: {
            apsap_cancel(self.handle)
        }
        try Task.checkCancellation()
        return value
    }

    func prepare() async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let success = apsap_prepare(handle, &error)
            try Self.check(success == 0, error: error)
        }
    }

    func exchange(version: UInt32, data: Data) async throws -> (data: Data, state: Int32) {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            var output: UnsafeMutablePointer<UInt8>?
            var count: UInt64 = 0
            var state: Int32 = -1
            defer { apsap_free(output) }
            let success = data.withUnsafeBytes { bytes in
                apsap_exchange(handle, version, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), &output, &count, &state, &error)
            }
            try Self.check(success == 0, error: error)
            guard count <= 1_048_576, count == 0 || output != nil else { throw AuthenticationError.signingFailed("Invalid handshake buffer.") }
            return (output.map { Data(bytes: $0, count: Int(count)) } ?? Data(), state)
        }
    }

    func sign(_ data: Data) async throws -> Data {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            var output: UnsafeMutablePointer<UInt8>?
            var count: UInt64 = 0
            defer { apsap_free(output) }
            let success = data.withUnsafeBytes { bytes in
                apsap_sign(handle, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), &output, &count, &error)
            }
            try Self.check(success == 0, error: error)
            guard let output, (1 ... 1_048_576).contains(count) else { throw AuthenticationError.signingFailed("Invalid signature buffer.") }
            return Data(bytes: output, count: Int(count))
        }
    }

    func close() async {
        let released = await withCheckedContinuation { continuation in
            queue.async {
                guard !self.closed else { continuation.resume(returning: false); return }
                self.closed = true
                apsap_close(self.handle)
                continuation.resume(returning: true)
            }
        }
        if released { await SAPSessionPermit.shared.release() }
    }
}
#endif
