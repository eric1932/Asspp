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
    // Confined to messageQueue.
    private nonisolated(unsafe) let file = LogFile()

    func write(_ content: String) {
        messageQueue.async {
            let timestamp = self.timestampFormatter.string(from: Date())
            let logMessage = "[\(timestamp)]\n\(content)"
            self.file.append("\(timestamp) \(content)")
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

/// The log on disk, so it can be read off a device over USB after the app has quit:
/// Library/Logs/Asspp.log, and the file before it as Asspp.log.1. Each holds at most
/// `maxBytes`, and Apple IDs are masked. Not thread-safe; LogManager confines it to its queue.
private final nonisolated class LogFile {
    private static let maxBytes: UInt64 = 512 * 1024
    private static let appleID = try? NSRegularExpression(
        pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive,
    )

    private let url: URL
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Asspp.log")
        // Earlier debug builds left a file that never shrank and held Apple IDs in plain text.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("Asspp-debug.log"))
        open()
    }

    func append(_ line: String) {
        if size >= Self.maxBytes {
            rotate()
        }
        guard let handle else { return }
        let data = Data((Self.masked(line) + "\n").utf8)
        if (try? handle.write(contentsOf: data)) != nil {
            size += UInt64(data.count)
        }
    }

    static func masked(_ text: String) -> String {
        guard let appleID else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return appleID.stringByReplacingMatches(in: text, range: range, withTemplate: "<apple-id>")
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        open()
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
