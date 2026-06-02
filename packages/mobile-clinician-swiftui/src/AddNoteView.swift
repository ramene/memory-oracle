// AddNoteView.swift
//
// Step 6 of the EBR demo: clinician enters a proposed clinical assertion
// (observation, prescription, order). The entry is POSTed to the
// /ebr-alert endpoint on the relay BEFORE being committed anywhere.
// Server response is either:
//   - conflict=false → entry would be safe (audit-log it locally; in
//                       production this would write to the EHR)
//   - conflict=true  → render the AI Overview banner via EBRAlertView,
//                       letting clinician acknowledge or override

import SwiftUI
import Combine

struct AddNoteView: View {
    let patientId: String                  // e.g. "jane-doe-1959"
    let availableScopes: [String]          // scopes the clinician decrypted in this encounter
    let clinicianName: String
    let relayBaseUrl: String
    var onSubmittedNoConflict: (String, String) -> Void   // scope, assertion
    var onConflictDetected: (EBRAlertResult) -> Void
    var onCancel: () -> Void

    @State private var selectedScope: String
    @State private var assertion: String = ""
    @State private var busy = false
    @State private var error: String? = nil

    init(patientId: String,
         availableScopes: [String],
         clinicianName: String,
         relayBaseUrl: String,
         onSubmittedNoConflict: @escaping (String, String) -> Void,
         onConflictDetected: @escaping (EBRAlertResult) -> Void,
         onCancel: @escaping () -> Void) {
        self.patientId = patientId
        self.availableScopes = availableScopes
        self.clinicianName = clinicianName
        self.relayBaseUrl = relayBaseUrl
        self.onSubmittedNoConflict = onSubmittedNoConflict
        self.onConflictDetected = onConflictDetected
        self.onCancel = onCancel
        self._selectedScope = State(initialValue: availableScopes.first ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Scope")) {
                    Picker("Scope", selection: $selectedScope) {
                        ForEach(availableScopes, id: \.self) { s in
                            Text(s).tag(s)
                        }
                    }
                }
                Section(header: Text("Proposed assertion")) {
                    TextEditor(text: $assertion)
                        .frame(minHeight: 100)
                    Text("Examples:\n  • \"administer FFP 2 units for active GI bleed\"\n  • \"prescribe amoxicillin 500mg PO TID\"\n  • \"start metoprolol 25mg BID\"")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let e = error {
                    Section { Text(e).font(.caption).foregroundColor(.red) }
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else {
                                Text("Check & submit").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(busy || assertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section(header: Text("What happens next")) {
                    Text("Your entry is checked against the patient's accretive record (citation chain + amendments) BEFORE being committed. If it conflicts with current truth, the AI Overview surfaces the relevant prior context. You can still override if clinically necessary.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add note / order")
            .navigationBarItems(trailing: Button("Cancel") { onCancel() })
        }
    }

    private func submit() {
        busy = true
        error = nil
        let trimmed = assertion.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let result = try await EBRClient.checkAlert(
                    relayBaseUrl: relayBaseUrl,
                    patientId: patientId,
                    scope: selectedScope,
                    proposedAssertion: trimmed,
                    proposedBy: clinicianName
                )
                if result.conflict {
                    AuditStore.append(AuditEntry(
                        event: "ebr_alert_conflict",
                        scopes: [selectedScope],
                        note: "kind=\(result.conflictKind ?? "?") severity=\(result.severity ?? "?")"
                    ))
                    onConflictDetected(result)
                } else {
                    AuditStore.append(AuditEntry(
                        event: "note_submitted_no_conflict",
                        scopes: [selectedScope],
                        note: trimmed.prefix(80).description
                    ))
                    onSubmittedNoConflict(selectedScope, trimmed)
                }
            } catch {
                self.error = "EBR check failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - HTTP client for /ebr-alert + result type

struct EBRAlertResult: Codable {
    let conflict: Bool
    let severity: String?
    let conflictKind: String?
    let proposedAssertion: String?
    let proposedBy: String?
    let citationCard: CitationCard?
    let aiOverview: AIOverview?
}

struct CitationCard: Codable {
    let patientId: String
    let scope: String
    let found: Bool
    let currentAssertion: String?
    let originalAssertion: String?
    let supersessionChain: [Amendment]?
    let sources: [Source]?
    let policy: String?
    let policyExplanation: String?
}

struct Amendment: Codable, Identifiable {
    var id: String { ts }
    let ts: String
    let author: String
    let supersedes: String?
    let current: String?
    let reason: String?
    let reversal_agent: String?
    let sidecar_id: String?
    let amendment_type: String?
}

struct Source: Codable, Identifiable {
    var id: String { path }
    let kind: String
    let path: String
    let mtime: String
    let sha256: String
}

struct AIOverview: Codable {
    let tldr: String
    let explanation: String
    let sources: [OverviewSource]
    let framing: String
    let severity: String?
}

struct OverviewSource: Codable, Identifiable {
    var id: String { label }
    let label: String
    let text: String?
    let currentAssertion: String?
    let mtime: String?
    let sidecarId: String?
}

enum EBRClient {
    static func checkAlert(relayBaseUrl: String,
                           patientId: String,
                           scope: String,
                           proposedAssertion: String,
                           proposedBy: String) async throws -> EBRAlertResult {
        let baseUrl = relayBaseUrl.hasSuffix("/") ? String(relayBaseUrl.dropLast()) : relayBaseUrl
        guard let url = URL(string: "\(baseUrl)/ebr-alert") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "patientId": patientId,
            "scope": scope,
            "proposedAssertion": proposedAssertion,
            "proposedBy": proposedBy,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "EBRClient", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(bodyText)"
            ])
        }
        return try JSONDecoder().decode(EBRAlertResult.self, from: data)
    }
}
