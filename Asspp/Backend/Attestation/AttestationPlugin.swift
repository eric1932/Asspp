//
//  AttestationPlugin.swift
//  Asspp
//
//  Created on 2026/11/12.
//

import Foundation

/// An attestation plugin loaded into the app: a library that exports
/// `asspp_attestation_plugin_v1`, as in the protocol at
/// https://github.com/eric1932/asspp-attest/blob/main/docs/PROTOCOL.md.
///
/// Asspp does not ship one. On iOS a user adds one to the app's Frameworks
/// folder when signing the IPA; on macOS they can also drop it into
/// Application Support/Asspp/Plugins. Asspp only looks the plugin up at
/// runtime and talks to it through four C function pointers; nothing is linked in.
final class AttestationPlugin: @unchecked Sendable {
    typealias Entry = @convention(c) () -> UnsafeRawPointer?
    typealias Configure = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias Call = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt64, UInt64,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt64>?
    ) -> Int32
    typealias Cancel = @convention(c) (UInt64) -> Void
    typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static let entrySymbol = "asspp_attestation_plugin_v1"
    /// Where a plugin is looked for when it was not loaded at launch.
    static let frameworkPath = "AssppAttest.framework/AssppAttest"

    /// Byte layout of the v1 table: size and api (UInt32 each), then four pointers.
    private static let tableSize = 8 + 4 * MemoryLayout<UnsafeRawPointer>.size

    let configure: Configure
    let call: Call
    let cancel: Cancel
    let release: Release

    private init(configure: Configure, call: Call, cancel: Cancel, release: Release) {
        self.configure = configure
        self.call = call
        self.cancel = cancel
        self.release = release
    }

    /// Folders searched for `AssppAttest.framework`: the app's own Frameworks folder (where a
    /// signing tool puts an injected framework) and, on macOS, a plugin folder the user can
    /// drop it into without touching the app.
    static var searchFolders: [URL] {
        var folders = [Bundle.main.privateFrameworksURL].compactMap { $0 }
        #if os(macOS)
            if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                folders.append(support.appendingPathComponent("Asspp/Plugins", isDirectory: true))
            }
        #endif
        return folders
    }

    /// The plugin in this process, loading it from a search folder if needed.
    /// Nil when there is none or its table is not version 1.
    static func load() -> AttestationPlugin? {
        if let plugin = resolve() {
            return plugin
        }

        for folder in searchFolders {
            let path = folder.appendingPathComponent(frameworkPath).path
            guard FileManager.default.fileExists(atPath: path) else { continue }

            // RTLD_GLOBAL: a plugin may look up its own dependencies with dlsym(RTLD_DEFAULT, ...).
            guard dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
                logger.error("device attestation: could not load the plugin at \(path): \(reason)")
                continue
            }
            if let plugin = resolve() {
                logger.info("device attestation: loaded the plugin from \(folder.path)")
                return plugin
            }
        }
        return nil
    }

    private static func resolve() -> AttestationPlugin? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, entrySymbol) else { return nil }
        let entry = unsafeBitCast(symbol, to: Entry.self)
        guard let table = entry() else { return nil }

        let size = table.load(as: UInt32.self)
        let api = table.load(fromByteOffset: 4, as: UInt32.self)
        guard api == 1, Int(size) >= tableSize else {
            logger.error("device attestation: unsupported plugin table (api \(api), size \(size))")
            return nil
        }

        func pointer(_ index: Int) -> UnsafeRawPointer? {
            table.load(fromByteOffset: 8 + index * MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer?.self)
        }
        guard let configure = pointer(0), let call = pointer(1), let cancel = pointer(2), let release = pointer(3) else {
            logger.error("device attestation: plugin table has empty entries")
            return nil
        }
        return AttestationPlugin(
            configure: unsafeBitCast(configure, to: Configure.self),
            call: unsafeBitCast(call, to: Call.self),
            cancel: unsafeBitCast(cancel, to: Cancel.self),
            release: unsafeBitCast(release, to: Release.self),
        )
    }
}
