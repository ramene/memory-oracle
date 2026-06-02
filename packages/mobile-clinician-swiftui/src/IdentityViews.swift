// IdentityViews.swift
//
// SwiftUI views for the multi-identity flow:
//   - IdentityListView   — full list + add + switch (presented as a sheet)
//   - AddIdentityView    — form for new identity (name + PIN ×2)
//   - SwitchAuthView     — PIN entry → Face ID gate → setActive
//   - FirstIdentitySetup — shown on app launch when no identities exist

import SwiftUI
import LocalAuthentication
import Combine

// MARK: - Identity list (presented as a sheet from HomeView gear)

struct IdentityListView: View {
    var onSwitched: () -> Void
    var onDismiss: () -> Void

    @State private var identities: [ClinicianIdentity] = []
    @State private var activeId: String? = nil
    @State private var switching: ClinicianIdentity? = nil
    @State private var addingNew = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Identities on this device")) {
                    ForEach(identities) { identity in
                        Button(action: { tap(identity) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(identity.name).font(.headline)
                                    Text(String(identity.recipient.prefix(28)) + "…")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if identity.id == activeId {
                                    Text("active")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button(action: { addingNew = true }) {
                        Label("Add new identity", systemImage: "person.badge.plus")
                    }
                }
                Section(header: Text("Security")) {
                    Text("Switching identity requires both the identity's PIN (what you know) AND Face ID against its SE-bound key (who you are). PINs are stored as salted SHA-256 hashes; SE keys never leave this device.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Identities")
            .navigationBarItems(trailing: Button("Done") { onDismiss() })
            .onAppear { reload() }
            .sheet(item: $switching) { identity in
                SwitchAuthView(identity: identity, onSuccess: {
                    switching = nil
                    reload()
                    onSwitched()
                }, onCancel: { switching = nil })
            }
            .sheet(isPresented: $addingNew, onDismiss: { reload() }) {
                AddIdentityView(onDone: { addingNew = false })
            }
        }
    }

    private func tap(_ identity: ClinicianIdentity) {
        if identity.id == activeId { onDismiss(); return }
        switching = identity
    }

    private func reload() {
        identities = IdentityStore.all()
        activeId = IdentityStore.activeId()
    }
}

// MARK: - Add identity

struct AddIdentityView: View {
    var onDone: () -> Void

    @State private var name = ""
    @State private var pin = ""
    @State private var pinConfirm = ""
    @State private var busy = false
    @State private var error: String? = nil
    @State private var success = false
    @Environment(\.presentationMode) var presentation

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Clinician")) {
                    TextField("Full name (e.g. Dr. R. Singh)", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                }
                Section(header: Text("PIN")) {
                    SecureField("PIN (4+ digits)", text: $pin)
                        .keyboardType(.numberPad)
                    SecureField("Confirm PIN", text: $pinConfirm)
                        .keyboardType(.numberPad)
                }
                if let e = error {
                    Text(e).font(.caption).foregroundColor(.red)
                }
                Section {
                    Button(action: create) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else {
                                Text(success ? "Created ✓" : "Create identity").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(busy || name.isEmpty || pin.count < 4 || pin != pinConfirm)
                }
                Section(header: Text("What happens")) {
                    Text("A new Secure Enclave keypair will be generated for this identity. Your PIN will be stored as a salted SHA-256 hash. The SE private key never leaves this device.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add identity")
            .navigationBarItems(trailing: Button("Cancel") { onDone() })
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            do {
                let identity = try IdentityStore.create(name: name, pin: pin)
                AuditStore.append(AuditEntry(
                    event: "identity_created",
                    patientRecipientPrefix: String(identity.recipient.prefix(20)),
                    note: "name=\(identity.name)"
                ))
                success = true
                try? await Task.sleep(nanoseconds: 600_000_000)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Switch identity (PIN + Face ID)

struct SwitchAuthView: View {
    let identity: ClinicianIdentity
    var onSuccess: () -> Void
    var onCancel: () -> Void

    @State private var pin = ""
    @State private var error: String? = nil
    @State private var step: Step = .pin
    @State private var busy = false

    enum Step { case pin, faceID, done }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Switch to").font(.caption).foregroundColor(.secondary)
                    Text(identity.name).font(.title2).fontWeight(.bold)
                    Text(String(identity.recipient.prefix(36)) + "…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 30)

                switch step {
                case .pin:
                    Text("Step 1 of 2 — Enter PIN")
                        .font(.headline)
                    SecureField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
                        .cornerRadius(8)
                    if let e = error {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                    Button(action: verifyPin) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Next").fontWeight(.semibold) }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .foregroundColor(.white)
                        .background(pin.count >= 4 && !busy
                                    ? Color(red: 0.07, green: 0.4, blue: 0.65)
                                    : Color.gray)
                        .cornerRadius(10)
                    }
                    .disabled(busy || pin.count < 4)

                case .faceID:
                    Text("Step 2 of 2 — Face ID")
                        .font(.headline)
                    Text("Confirm with Face ID against this identity's Secure Enclave key.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let e = error {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                    Button(action: runFaceID) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Run Face ID").fontWeight(.semibold) }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .foregroundColor(.white)
                        .background(busy ? Color.gray : Color(red: 0.07, green: 0.4, blue: 0.65))
                        .cornerRadius(10)
                    }
                    .disabled(busy)

                case .done:
                    EmptyView()
                }

                Spacer()
            }
            .padding(24)
            .navigationBarItems(trailing: Button("Cancel") { onCancel() })
        }
    }

    private func verifyPin() {
        busy = true
        error = nil
        Task {
            do {
                try IdentityStore.verifyPin(identityId: identity.id, pin: pin)
                step = .faceID
            } catch {
                self.error = error.localizedDescription
                AuditStore.append(AuditEntry(
                    event: "identity_switch_pin_failed",
                    note: "target=\(identity.name)"
                ))
            }
            busy = false
        }
    }

    private func runFaceID() {
        busy = true
        error = nil
        let context = LAContext()
        var canEvalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canEvalError) else {
            error = "Face ID unavailable: \(canEvalError?.localizedDescription ?? "")"
            busy = false
            return
        }
        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Switch to \(identity.name)"
                )
                guard success else {
                    error = "Face ID cancelled"
                    busy = false
                    return
                }
                try IdentityStore.setActive(identity.id)
                AuditStore.append(AuditEntry(
                    event: "identity_switched",
                    note: "to=\(identity.name)"
                ))
                onSuccess()
            } catch {
                self.error = "Face ID failed: \(error.localizedDescription)"
                AuditStore.append(AuditEntry(
                    event: "identity_switch_faceid_failed",
                    note: "target=\(identity.name)"
                ))
            }
            busy = false
        }
    }
}

// MARK: - First-launch identity setup (no identities exist)

struct FirstIdentitySetup: View {
    var onCreated: () -> Void

    @State private var addingNew = true

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 60))
                .foregroundColor(Color(red: 0.07, green: 0.4, blue: 0.65))
            Text("memory-oracle Dr.")
                .font(.title).fontWeight(.bold)
            Text("Welcome. To begin, set up a clinician identity. Each identity gets its own Secure Enclave key and PIN — switching between them requires both factors.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: { addingNew = true }) {
                Text("Set up first identity")
                    .foregroundColor(.white).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(16)
                    .background(Color(red: 0.07, green: 0.4, blue: 0.65))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24).padding(.bottom, 30)
        }
        .sheet(isPresented: $addingNew, onDismiss: {
            // If an identity was created during the sheet, transition to home
            if !IdentityStore.all().isEmpty {
                // Auto-activate the first identity (no switch challenge needed on first creation)
                if IdentityStore.activeId() == nil,
                   let first = IdentityStore.all().first {
                    try? IdentityStore.setActive(first.id)
                }
                onCreated()
            }
        }) {
            AddIdentityView(onDone: { addingNew = false })
        }
    }
}
