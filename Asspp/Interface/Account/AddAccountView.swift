//
//  AddAccountView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import SwiftUI

struct AddAccountView: View {
    private let accountEmail: String?
    @State private var vm = AppStore.this
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isPasswordHidden = true

    @State private var codeRequired: Bool = false
    @State private var code: String = ""

    @State private var error: Error?
    @State private var progress: AuthenticationProgress?
    @State private var authenticationTask: Task<Void, Never>?

    init(accountEmail: String? = nil) {
        self.accountEmail = accountEmail
        _email = State(initialValue: accountEmail ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Email (Apple ID)", text: $email)
                    .disabled(authenticationTask != nil || accountEmail != nil)
                #if os(iOS)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                #endif
                if isPasswordHidden {
                    SecureField("Password", text: $password)
                        .disabled(authenticationTask != nil)
                    #if os(iOS)
                        .textContentType(.password)
                    #endif
                } else {
                    TextField(text: $password) {
                        Text("Password")
                            .font(.body)
                    }
                    #if os(iOS)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textContentType(.password)
                    #endif
                    .font(.body.monospaced())
                    .disabled(authenticationTask != nil)
                }
            } header: {
                HStack {
                    Text("Apple ID")
                    Spacer()
                    Button(isPasswordHidden ? "Show Password" : "Hide Password") {
                        isPasswordHidden.toggle()
                    }
                    .disabled(password.isEmpty)
                }
            } footer: {
                if accountEmail != nil {
                    Text("Enter your current Apple Account password. Your saved account is updated only after a successful sign-in.")
                } else {
                    Text("Your account is saved in your Keychain and will be synced across devices with the same iCloud account signed in.")
                }
            }
            if codeRequired {
                Section {
                    TextField("2FA Code (Optional)", text: $code)
                        .disabled(authenticationTask != nil)
                    #if os(iOS)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    #endif
                } header: {
                    Text("2FA Code")
                } footer: {
                    Text("If Apple sent you a verification code, enter it here. Otherwise, check your Apple ID and password.\n\nhttps://support.apple.com/102606")
                }
                .transition(.opacity)
            }
            Section {
                Button("Authenticate", action: authenticate)
                    .disabled(email.isEmpty || password.isEmpty || authenticationTask != nil)
                if !codeRequired {
                    Button("Enter Verification Code") { codeRequired = true }
                        .disabled(authenticationTask != nil)
                }
                if authenticationTask != nil {
                    HStack {
                        ProgressView()
                        if let progress { Text(progressLabel(progress)) }
                    }
                    Button("Cancel") { authenticationTask?.cancel() }
                }
            } footer: {
                if let error {
                    Text(error.localizedDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .transition(.opacity)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.spring, value: codeRequired)
        .onDisappear { authenticationTask?.cancel() }
        .onChange(of: email) { codeRequired = false; code = "" }
        .onChange(of: password) { code = "" }
        #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .navigationTitle(accountEmail == nil ? Text("Add Account") : Text("Reauthenticate Account"))
    }

    private func authenticate() {
        error = nil
        authenticationTask = Task { @MainActor in
            defer { progress = nil; authenticationTask = nil }
            do {
                _ = try await vm.authenticate(email: email, password: password, code: code) { phase in
                    Task { @MainActor in progress = phase }
                }
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                // A user cancellation is not a failed login or a code challenge.
            } catch {
                self.error = error
                if let authenticationError = error as? ApplePackage.AuthenticationError,
                   authenticationError == .invalidVerificationCode {
                    codeRequired = true
                }
                logger.error("authentication failed")
            }
        }
    }

    private func progressLabel(_ progress: AuthenticationProgress) -> LocalizedStringKey {
        switch progress {
        case .loadingConfiguration: "Loading sign-in configuration…"
        case .preparingResources: "Preparing signing resources…"
        case .preparingSignature: "Preparing secure sign-in…"
        case .signing: "Signing sign-in request…"
        case .authenticating: "Signing in…"
        }
    }

}
