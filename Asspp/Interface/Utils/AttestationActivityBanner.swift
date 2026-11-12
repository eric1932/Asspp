//
//  AttestationActivityBanner.swift
//  Asspp
//
//  Created on 2026/11/12.
//

import SwiftUI

/// A strip above the content while device attestation runs: the step, how long it has
/// taken, and how much of Apple's components the first download has got.
struct AttestationActivityBanner: View {
    @State private var activity = AttestationActivity.shared

    var body: some View {
        VStack {
            if let entry = activity.current {
                content(entry)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activity.current?.id)
    }

    private func content(_ entry: AttestationActivity.Entry) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(entry))
                    .font(.footnote.weight(.semibold))
                Group {
                    if let bytes = entry.downloadedBytes {
                        Text("\(bytes.formatted(.byteCount(style: .file))) downloaded")
                    } else {
                        Text("Device Attestation")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(entry.startedAt, style: .timer)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private func title(_ entry: AttestationActivity.Entry) -> LocalizedStringKey {
        if entry.downloadedBytes != nil {
            return "Downloading Apple components (first time only)"
        }
        switch entry.step {
        case .downloadingComponents: return "Downloading Apple components (first time only)"
        case .machineIdentity: return "Getting a machine identity"
        case .registeringDevice: return "Registering this device with Apple"
        case .signingRequest: return "Signing the request"
        case .generatingDownloadKey: return "Generating the download key"
        case .working: return "Device Attestation"
        }
    }
}

extension View {
    /// Shows `AttestationActivityBanner` at the bottom while device attestation runs.
    func attestationActivityBanner() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            AttestationActivityBanner()
        }
    }
}
