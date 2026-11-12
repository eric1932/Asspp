//
//  PluginAttestationTransport.swift
//  Asspp
//
//  Created on 2026/11/12.
//

import ApplePackage
import Foundation

/// Device attestation from a plugin loaded into the app (see `AttestationPlugin`).
struct PluginAttestationTransport: AttestationServiceTransport {
    let plugin: AttestationPlugin
    let summary: String

    /// Nil when no plugin is present, or it cannot be set up.
    static func make() -> PluginAttestationTransport? {
        guard let plugin = AttestationPlugin.load() else { return nil }
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
            )
            let state = support.appendingPathComponent("AttestationPlugin", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            guard state.path.withCString({ plugin.configure($0) }) == 0 else {
                logger.error("device attestation: the plugin rejected its state directory")
                return nil
            }
        } catch {
            logger.error("device attestation: plugin setup failed: \(error.localizedDescription)")
            return nil
        }

        let info = Self.info(plugin)
        let summary = [info?.name ?? "a plugin", info?.version, info?.license.map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
        return PluginAttestationTransport(plugin: plugin, summary: "plugin \(summary)")
    }

    func send(_ method: String, body: Data) async throws -> (status: Int, body: Data) {
        let plugin = plugin
        let token = Self.tokens.next()
        let canceled = Flag()
        // One emulator operation runs at a time; info and health answer meanwhile.
        let queue = method == "health" || method == "info" ? Self.statusQueue : Self.queue

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int, body: Data), Error>) in
                queue.async {
                    if canceled.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: Self.invoke(plugin, method, body, token))
                }
            }
        } onCancel: {
            canceled.set()
            plugin.cancel(token)
        }
    }

    private static func invoke(_ plugin: AttestationPlugin, _ method: String, _ body: Data, _ token: UInt64) -> (status: Int, body: Data) {
        var response: UnsafeMutablePointer<UInt8>?
        var length: UInt64 = 0
        let status = method.withCString { name in
            body.withUnsafeBytes { bytes in
                plugin.call(name, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), token, &response, &length)
            }
        }
        let data = response.map { Data(bytes: $0, count: Int(length)) } ?? Data()
        plugin.release(UnsafeMutableRawPointer(response))
        return (status == 0 ? 200 : Int(status), data)
    }

    private struct Info: Decodable {
        let name: String?
        let version: String?
        let license: String?
    }

    private static func info(_ plugin: AttestationPlugin) -> Info? {
        let (status, data) = invoke(plugin, "info", Data(), 0)
        guard status == 200 else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    private static let queue = DispatchQueue(label: "wiki.qaq.asspp.attestation.plugin", qos: .userInitiated)
    private static let statusQueue = DispatchQueue(label: "wiki.qaq.asspp.attestation.plugin.status", qos: .utility)
    private static let tokens = TokenSource()
}

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
