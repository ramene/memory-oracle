// EncounterRequestView.swift
//
// After QR scan: pre-filled patient recipient + relay URL (from QR),
// scope picker (multi-select chips), TTL slider, Send button → POSTs
// EncounterRequest to the relay. Transitions to WaitingView with the
// returned encounterId.

import SwiftUI
import Combine

struct EncounterRequestView: View {
    let patient: PatientQRPayload
    let clinicianRecipient: String
    let clinicianName: String
    var onSubmitted: (String, EncounterRequest, RelayClient) -> Void
    var onCancel: () -> Void

    @State private var selectedScopes: Set<String> = ["allergies", "meds"]
    @State private var ttlMinutes: Double = 15
    @State private var busy = false
    @State private var error: String? = nil

    private let availableScopes = ["allergies", "meds", "recent-labs", "past-procedures"]

    private var ttlSeconds: Int { Int(ttlMinutes * 60) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onCancel) {
                    Text("← cancel")
                        .font(.callout)
                        .foregroundColor(.blue)
                }
                .padding(.top, 30)

                Text("Configure encounter")
                    .font(.title).fontWeight(.bold)

                patientCard
                scopePicker
                ttlSlider
                if let e = error { errorBox(e) }
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if busy { ProgressView().tint(.white) } else {
                            Text("Send to patient").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 18)
                    .background(canSubmit
                                ? Color(red: 0.07, green: 0.4, blue: 0.65)
                                : Color.gray)
                    .cornerRadius(12)
                }
                .disabled(!canSubmit)

                Text("The patient's iPhone will show this request as 'Pending'. They tap to review, approve via Face ID. Wrapped session keys come back encrypted to your Secure Enclave.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }

    private var canSubmit: Bool { !busy && !selectedScopes.isEmpty }

    private var patientCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From scanned QR").font(.caption).foregroundColor(.secondary)
            Text("Patient recipient:")
                .font(.caption2).foregroundColor(.secondary)
            Text(patient.recipient)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            Text("Relay: \(patient.relay)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.98, blue: 0.94))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.83, green: 0.87, blue: 0.69), lineWidth: 1))
        .cornerRadius(10)
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requested scopes")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(Color(red: 0.27, green: 0.27, blue: 0.27))
            FlowLayout(spacing: 8) {
                ForEach(availableScopes, id: \.self) { scope in
                    let selected = selectedScopes.contains(scope)
                    Button(action: { toggle(scope) }) {
                        Text(scope)
                            .font(.callout)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected
                                        ? Color(red: 0.07, green: 0.4, blue: 0.65)
                                        : Color(red: 0.95, green: 0.95, blue: 0.97))
                            .foregroundColor(selected ? .white : .primary)
                            .cornerRadius(16)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.87, green: 0.88, blue: 0.9), lineWidth: 1))
        .cornerRadius(10)
    }

    private var ttlSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Encounter TTL")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text("\(Int(ttlMinutes)) min")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.blue)
            }
            Slider(value: $ttlMinutes, in: 5...60, step: 5)
            Text("After expiry, the wrapped session keys cannot be used to decrypt records on this device.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.87, green: 0.88, blue: 0.9), lineWidth: 1))
        .cornerRadius(10)
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.footnote).foregroundColor(Color(red: 0.45, green: 0.13, blue: 0.13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.99, green: 0.92, blue: 0.92))
            .cornerRadius(8)
    }

    // MARK: - actions

    private func toggle(_ scope: String) {
        if selectedScopes.contains(scope) { selectedScopes.remove(scope) }
        else                              { selectedScopes.insert(scope) }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task {
            let client = RelayClient(baseUrl: patient.relay)
            let request = EncounterRequest(
                type: "EncounterRequest",
                encounterId: UUID().uuidString,    // server replaces
                clinicianRecipient: clinicianRecipient,
                clinicianName: clinicianName,
                patientRecipient: patient.recipient,
                requestedScopes: Array(selectedScopes).sorted(),
                ttlSeconds: ttlSeconds,
                issuedAt: ISO8601DateFormatter().string(from: Date())
            )
            do {
                let response = try await client.submitEncounterRequest(request)
                AuditStore.append(AuditEntry(
                    event: "encounter_request_sent",
                    encounterId: response.encounterId,
                    patientRecipientPrefix: String(patient.recipient.prefix(20)),
                    scopes: Array(selectedScopes).sorted(),
                    expiresAt: response.expiresAt
                ))
                onSubmitted(response.encounterId, request, client)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

// Same FlowLayout helper as patient app (iOS 16+ Layout protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxRowW: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                maxRowW = max(maxRowW, x - spacing)
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        maxRowW = max(maxRowW, x - spacing)
        return CGSize(width: max(0, maxRowW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
