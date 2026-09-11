//
//  AccountDetailView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import SwiftUI

struct AccountDetailView: View {
    let accountId: AppStore.UserAccount.ID

    @State private var vm = AppStore.this
    @Environment(\.dismiss) var dismiss

    private var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == accountId }
    }

    @State private var rotatingHint = ""
    @State private var rotationSucceeded = false
    @State private var isRotating = false
    @State private var showsReauthentication = false

    var body: some View {
        Form {
            Section {
                Button { copyToClipboard(account?.account.email) } label: {
                    Text(account?.account.email ?? "")
                }
                .foregroundStyle(.primary)
                .redacted(reason: .placeholder, isEnabled: vm.demoMode)
            } header: {
                Text("Apple ID")
            } footer: {
                Text("This email is used to sign in to Apple services.")
            }
            Section {
                Button { copyToClipboard(account?.account.store) } label: {
                    Text("\(account?.account.store ?? "") - \(ApplePackage.Configuration.countryCode(for: account?.account.store ?? "") ?? "Unknown")")
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Country Code")
            } footer: {
                Text("App Store requires this country code to identify your package region.")
            }
            Section {
                Button { copyToClipboard(account?.account.directoryServicesIdentifier) } label: {
                    Text(account?.account.directoryServicesIdentifier ?? "")
                        .font(.system(.body, design: .monospaced))
                }
                .foregroundStyle(.primary)
                .redacted(reason: .placeholder, isEnabled: vm.demoMode)
            } header: {
                Text("Directory Services ID")
            } footer: {
                Text("This ID, combined with a random seed generated on this device, can be used to download packages from the App Store.")
            }
            Section {
                SecureField(text: .constant(account?.account.passwordToken ?? "")) {
                    Text("Password Token")
                }
                AsyncButton {
                    isRotating = true
                    rotatingHint = ""
                    rotationSucceeded = false
                    defer { isRotating = false }
                    do {
                        try await vm.rotate(id: account?.id ?? "")
                        rotatingHint = String(localized: "Success")
                        rotationSucceeded = true
                    } catch {
                        rotatingHint = error.localizedDescription
                        throw error
                    }
                } label: {
                    Text("Rotate Token")
                }
                .disabledWhenLoading()
                Button("Reauthenticate Account") { showsReauthentication = true }
                    .disabled(isRotating || account == nil)
            } header: {
                Text("Password Token")
            } footer: {
                if rotatingHint.isEmpty {
                    Text("If you fail to acquire a license for a product, rotating the password token may help. This will use the initial password to authenticate with the App Store again.")
                } else {
                    Text(rotatingHint)
                        .foregroundStyle(rotationSucceeded ? Color.green : Color.red)
                }
                Text("If rotation fails, reauthenticate with your current password and a verification code if available. You do not need to delete this account.")
            }
            Section {
                Button("Delete") {
                    vm.delete(id: account?.id ?? "")
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account Details")
        .sheet(isPresented: $showsReauthentication, onDismiss: { rotatingHint = "" }) {
            if let account {
                NavigationStack {
                    AddAccountView(accountEmail: account.account.email)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showsReauthentication = false }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 500)
                #endif
            }
        }
    }
}
