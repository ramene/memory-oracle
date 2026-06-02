// ActiveEncounterView.swift
//
// After the clinician submits the EncounterRequest: polls the relay until
// the patient approves, then on approval received fires Face ID on this
// device for decryption, then renders the decrypted records with a live
// TTL countdown + auto-shred timer.
//
// This is the SINGLE view that depicts the LNCS §7.4 paper figure
// moment: clinician's iPad shows the decrypted record briefly, with the
// countdown visible — that's the screenshot.

import SwiftUI
import Combine

struct ActiveEncounterView: View {
    let encounterId: String
    let request: EncounterRequest
    let client: RelayClient
    let clinicianKeyTag: String
    let clinicianName: String
    let patientId: String
    let relayBaseUrl: String
    var onEnd: () -> Void

    @StateObject private var poller: ApprovalPoller
    @State private var decrypted: [DecryptedScope] = []
    @State private var decryptionState: DecryptionState = .awaitingApproval
    @State private var error: String? = nil
    @State private var secondsLeft: Int = 0
    @State private var expiresAtDate: Date? = nil
    @State private var showAddNote = false
    @State private var ebrAlert: EBRAlertResult? = nil

    enum DecryptionState {
        case awaitingApproval
        case decrypting
        case decrypted
        case expired
        case failed
    }

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(encounterId: String, request: EncounterRequest, client: RelayClient,
         clinicianKeyTag: String, clinicianName: String, patientId: String,
         relayBaseUrl: String, onEnd: @escaping () -> Void) {
        self.encounterId = encounterId
        self.request = request
        self.client = client
        self.clinicianKeyTag = clinicianKeyTag
        self.clinicianName = clinicianName
        self.patientId = patientId
        self.relayBaseUrl = relayBaseUrl
        self.onEnd = onEnd
        self._poller = StateObject(wrappedValue: ApprovalPoller(client: client, encounterId: encounterId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: end) {
                    Text("← end encounter")
                        .font(.callout)
                        .foregroundColor(.blue)
                }
                .padding(.top, 30)

                stateHeader

                if let e = error { errorBox(e) }

                switch decryptionState {
                case .awaitingApproval:
                    awaitingCard
                case .decrypting:
                    decryptingCard
                case .decrypted, .expired:
                    if !decrypted.isEmpty {
                        countdownCard
                        ForEach(decrypted) { ds in
                            recordCard(ds)
                        }
                        if decryptionState == .decrypted {
                            addNoteButton
                        }
                    }
                case .failed:
                    EmptyView()
                }

                Button(action: end) {
                    HStack {
                        Spacer()
                        Text("End encounter & shred")
                            .foregroundColor(.white)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                    .background(Color(red: 0.8, green: 0.27, blue: 0.27))
                    .cornerRadius(10)
                }
                .padding(.top, 16)
            }
            .padding(24)
        }
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
        .onReceive(poller.$approval) { approval in
            if let a = approval, decryptionState == .awaitingApproval {
                handleApproval(a)
            }
        }
        .onReceive(countdownTimer) { _ in tickCountdown() }
        .sheet(isPresented: $showAddNote) {
            AddNoteView(
                patientId: patientId,
                availableScopes: decrypted.map { $0.scope },
                clinicianName: clinicianName,
                relayBaseUrl: relayBaseUrl,
                onSubmittedNoConflict: { _, _ in
                    showAddNote = false
                },
                onConflictDetected: { result in
                    showAddNote = false
                    ebrAlert = result
                },
                onCancel: { showAddNote = false }
            )
        }
        .sheet(item: Binding(
            get: { ebrAlert.map { EBRAlertWrapper(result: $0) } },
            set: { ebrAlert = $0?.result }
        )) { wrapper in
            EBRAlertView(
                result: wrapper.result,
                onAcknowledge: {
                    AuditStore.append(AuditEntry(
                        event: "ebr_alert_acknowledged",
                        encounterId: encounterId
                    ))
                    ebrAlert = nil
                },
                onOverride: { reason in
                    AuditStore.append(AuditEntry(
                        event: "ebr_alert_overridden",
                        encounterId: encounterId,
                        note: "reason=\(reason.prefix(120))"
                    ))
                    ebrAlert = nil
                },
                onDismiss: { ebrAlert = nil }
            )
        }
    }

    private struct EBRAlertWrapper: Identifiable {
        var id: String { result.proposedAssertion ?? UUID().uuidString }
        let result: EBRAlertResult
    }

    private var addNoteButton: some View {
        Button(action: { showAddNote = true }) {
            HStack {
                Image(systemName: "square.and.pencil")
                Text("Add note / order").fontWeight(.semibold)
                Spacer()
            }
            .padding(14)
            .foregroundColor(Color(red: 0.07, green: 0.4, blue: 0.65))
            .background(Color(red: 0.94, green: 0.97, blue: 1.0))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.68, green: 0.78, blue: 0.93), lineWidth: 1))
            .cornerRadius(10)
        }
        .padding(.top, 8)
    }

    // MARK: - subviews

    private var stateHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Encounter").font(.title).fontWeight(.bold)
            Text("Patient: \(String(request.patientRecipient.prefix(24)))…")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var awaitingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text("Awaiting patient approval…").fontWeight(.semibold)
                Spacer()
                Text("\(poller.elapsedSeconds)s").font(.caption).foregroundColor(.secondary)
            }
            Text("The patient's iPhone is showing this request as pending. Once they tap Approve and Face ID succeeds, the wrapped session keys land here and this device's Face ID fires to decrypt.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Requested scopes: \(request.requestedScopes.joined(separator: ", "))")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.87, green: 0.88, blue: 0.9), lineWidth: 1))
        .cornerRadius(10)
    }

    private var decryptingCard: some View {
        HStack {
            ProgressView()
            Text("Decrypting with Face ID…").fontWeight(.semibold)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.96, green: 0.97, blue: 1.0))
        .cornerRadius(10)
    }

    private var countdownCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Records visible for")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(secondsLeft <= 0 ? "expired" : formatTtl(secondsLeft))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(secondsLeft <= 30 ? Color(red: 0.8, green: 0.27, blue: 0.27)
                                                       : Color(red: 0.13, green: 0.13, blue: 0.27))
            }
            Text("After expiry the session keys are no longer in memory; records evaporate.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(red: 0.99, green: 0.97, blue: 0.92))
        .cornerRadius(10)
    }

    private func recordCard(_ ds: DecryptedScope) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ds.scope)
                    .font(.headline)
                    .foregroundColor(Color(red: 0.13, green: 0.4, blue: 0.13))
                Spacer()
                Text("✓ decrypted")
                    .font(.caption2)
                    .foregroundColor(Color(red: 0.27, green: 0.6, blue: 0.27))
            }
            Text(ds.recordText)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Color(red: 0.13, green: 0.27, blue: 0.13))
                .padding(.vertical, 4)
            Text("session key: \(String(ds.sessionKeyHex.prefix(32)))…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 1.0, blue: 0.96))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.72, green: 0.85, blue: 0.66), lineWidth: 1))
        .cornerRadius(10)
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundColor(Color(red: 0.45, green: 0.13, blue: 0.13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.99, green: 0.92, blue: 0.92))
            .cornerRadius(8)
    }

    // MARK: - logic

    private func handleApproval(_ approval: EncounterApproval) {
        decryptionState = .decrypting
        AuditStore.append(AuditEntry(
            event: "approval_received",
            encounterId: encounterId,
            patientRecipientPrefix: String(request.patientRecipient.prefix(20)),
            scopes: Array(approval.wrappedKeys.keys).sorted(),
            expiresAt: approval.expiresAt
        ))

        expiresAtDate = ISO8601DateFormatter().date(from: approval.expiresAt)
        secondsLeft = expiresAtDate.map { max(0, Int($0.timeIntervalSinceNow)) } ?? 0

        Task {
            do {
                let results = try await DecryptHandler.decryptAll(
                    approval: approval, clinicianKeyTag: clinicianKeyTag)
                decrypted = results
                decryptionState = .decrypted
                AuditStore.append(AuditEntry(
                    event: "records_decrypted",
                    encounterId: encounterId,
                    scopes: results.map { $0.scope }
                ))
            } catch {
                self.error = error.localizedDescription
                decryptionState = .failed
                AuditStore.append(AuditEntry(
                    event: "decrypt_failed",
                    encounterId: encounterId,
                    note: error.localizedDescription
                ))
            }
        }
    }

    private func tickCountdown() {
        guard let expires = expiresAtDate else { return }
        let left = max(0, Int(expires.timeIntervalSinceNow))
        secondsLeft = left
        if left == 0, decryptionState == .decrypted {
            // Shred — clear session keys + records from memory
            decrypted = []
            decryptionState = .expired
            AuditStore.append(AuditEntry(
                event: "encounter_expired_shred",
                encounterId: encounterId
            ))
        }
    }

    private func end() {
        Task {
            await client.deleteEncounter(encounterId)
        }
        AuditStore.append(AuditEntry(
            event: "encounter_ended_by_clinician",
            encounterId: encounterId
        ))
        decrypted = []
        onEnd()
    }

    private func formatTtl(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
