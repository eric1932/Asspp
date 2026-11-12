//
//  AttestationActivity.swift
//  Asspp
//
//  Created on 2026/11/12.
//

import Foundation
import Observation

/// The device attestation steps running right now, for the progress banner.
/// Each step runs an emulator for seconds, and the first one also downloads Apple's components.
@Observable
@MainActor
final class AttestationActivity {
    static let shared = AttestationActivity()

    enum Step: Equatable {
        case downloadingComponents
        case machineIdentity
        case registeringDevice
        case signingRequest
        case generatingDownloadKey
        case working

        /// The step for an asspp-attestd method.
        init(method: String) {
            switch method {
            case "prepare": self = .downloadingComponents
            case "machine-headers": self = .machineIdentity
            case "provision": self = .registeringDevice
            case "store-headers": self = .signingRequest
            case "kbsync": self = .generatingDownloadKey
            default: self = .working
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let step: Step
        let startedAt = Date()
        /// Bytes of Apple's components downloaded so far, while the first download runs.
        var downloadedBytes: Int64?
    }

    private(set) var entries: [Entry] = []

    /// The most recent step still running.
    var current: Entry? {
        entries.last
    }

    func begin(_ step: Step) -> Entry.ID {
        let entry = Entry(step: step)
        entries.append(entry)
        return entry.id
    }

    func update(_ id: Entry.ID, downloadedBytes: Int64?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].downloadedBytes = downloadedBytes
    }

    func end(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }
}
