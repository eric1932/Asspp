//
//  LogManager.swift
//  Asspp
//
//  Created on 2026/2/20.
//

import Foundation
import Logging

final nonisolated class LogManager: Sendable {
    static let shared = LogManager()

    private static let maxMessages = 2000

    private let messageQueue = DispatchQueue(label: "wiki.qaq.log")
    // Confined to messageQueue, so a single formatter instance is safe to reuse.
    private nonisolated(unsafe) let timestampFormatter = ISO8601DateFormatter()
    private nonisolated(unsafe) var messages: [String] = []
    // DEBUG BUILD: mirror every message to ~/Library/Logs/Asspp-debug.log. Confined to messageQueue.
    private nonisolated(unsafe) let debugFile: FileHandle? = {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Asspp-debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    func write(_ content: String) {
        messageQueue.async {
            let timestamp = self.timestampFormatter.string(from: Date())
            let logMessage = "[\(timestamp)]\n\(content)"
            try? self.debugFile?.write(contentsOf: Data("\(timestamp) \(content)\n".utf8))
            self.messages.append(logMessage)
            // Cap retained history so a long-running session cannot grow memory
            // without bound.
            if self.messages.count > Self.maxMessages {
                self.messages.removeFirst(self.messages.count - Self.maxMessages)
            }
        }
    }

    func getMessages() -> [String] {
        messageQueue.sync { messages }
    }
}

struct LogManagerHandler: LogHandler {
    var logLevel: Logger.Level = .debug
    var metadata: Logger.Metadata = [:]
    let label: String

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt,
    ) {
        let text = "[\(level)] [\(label)] \(message)"
        Swift.print(text)
        LogManager.shared.write(text)
    }
}
