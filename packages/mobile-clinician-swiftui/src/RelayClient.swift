// RelayClient.swift  (clinician side)
//
// Mirrors the patient app's RelayClient but flipped: clinician POSTs
// EncounterRequest to the relay, polls for EncounterApproval. Same wire
// format (packages/encounter-relay/types.ts); same auth-less HTTP demo
// posture.

import Foundation
import SwiftUI
import Combine

// MARK: - Wire format (same as patient app)

struct PatientQRPayload: Codable, Equatable {
    let v: Int
    let recipient: String
    let relay: String
}

struct EncounterRequest: Codable, Identifiable, Equatable {
    let type: String
    let encounterId: String
    let clinicianRecipient: String
    let clinicianName: String
    let patientRecipient: String
    let requestedScopes: [String]
    let ttlSeconds: Int
    let issuedAt: String

    var id: String { encounterId }

    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case encounterId, clinicianRecipient, clinicianName, patientRecipient
        case requestedScopes, ttlSeconds, issuedAt
    }
}

struct EncounterApproval: Codable {
    let type: String
    let encounterId: String
    let wrappedKeys: [String: String]   // scope name → base64 of age-encrypted blob
    let expiresAt: String
    let auditEntryId: String?

    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case encounterId, wrappedKeys, expiresAt, auditEntryId
    }
}

struct EncounterPostResponse: Codable {
    let encounterId: String
    let expiresAt: String
}

// MARK: - Configuration

enum RelayConfig {
    /// Compile-time default; runtime override via UserDefaults["relayBaseUrl"].
    /// The patient's QR ALSO encodes the relay URL — clinician should use that
    /// once scanned, since the patient knows where their relay lives.
    static let defaultBaseUrl = "http://192.168.100.5:8080"

    static var baseUrl: String {
        UserDefaults.standard.string(forKey: "relayBaseUrl") ?? defaultBaseUrl
    }
}

// MARK: - HTTP errors

enum RelayError: LocalizedError {
    case invalidURL(String)
    case http(Int, String)
    case decode(String)
    case network(String)
    case awaitingApproval

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):      return "Invalid URL: \(s)"
        case .http(let code, let s):  return "HTTP \(code): \(s)"
        case .decode(let s):          return "Decode error: \(s)"
        case .network(let s):         return "Network error: \(s)"
        case .awaitingApproval:       return "Awaiting patient approval"
        }
    }
}

// MARK: - HTTP client

struct RelayClient {
    let baseUrl: String

    init(baseUrl: String = RelayConfig.baseUrl) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    }

    /// POST /encounter — clinician submits an EncounterRequest. Returns the
    /// server-assigned encounter ID.
    func submitEncounterRequest(_ request: EncounterRequest) async throws -> EncounterPostResponse {
        guard let url = URL(string: "\(baseUrl)/encounter") else { throw RelayError.invalidURL(baseUrl) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RelayError.network("non-HTTP response") }
        guard http.statusCode == 201 || http.statusCode == 200 else {
            throw RelayError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(EncounterPostResponse.self, from: data)
    }

    /// GET /encounter/<id>/approval — clinician polls for patient approval.
    /// Returns awaitingApproval until the patient submits.
    func fetchApproval(encounterId: String) async throws -> EncounterApproval {
        guard let url = URL(string: "\(baseUrl)/encounter/\(encounterId)/approval") else {
            throw RelayError.invalidURL(baseUrl)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RelayError.network("non-HTTP response") }
        if http.statusCode == 404 {
            throw RelayError.awaitingApproval
        }
        guard http.statusCode == 200 else {
            throw RelayError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(EncounterApproval.self, from: data)
        } catch {
            throw RelayError.decode(error.localizedDescription)
        }
    }

    /// DELETE /encounter/<id> — clean up after the demo.
    func deleteEncounter(_ encounterId: String) async {
        guard let url = URL(string: "\(baseUrl)/encounter/\(encounterId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    func ping() async -> Bool {
        guard let url = URL(string: "\(baseUrl)/healthz") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Approval poller

/// Polls the relay every 3s until the patient approves OR the operator
/// cancels. Lower interval than patient's pending-request poller because
/// the clinician is actively waiting.
@MainActor
final class ApprovalPoller: ObservableObject {
    @Published var approval: EncounterApproval? = nil
    @Published var loading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var elapsedSeconds: Int = 0

    private let client: RelayClient
    private let encounterId: String
    private var pollingTask: Task<Void, Never>?
    private var startTime: Date = .init()
    private let pollIntervalNs: UInt64 = 3 * 1_000_000_000

    init(client: RelayClient, encounterId: String) {
        self.client = client
        self.encounterId = encounterId
    }

    func start() {
        stop()
        startTime = Date()
        elapsedSeconds = 0
        pollingTask = Task { @MainActor in
            while !Task.isCancelled, approval == nil {
                await pollOnce()
                elapsedSeconds = Int(-startTime.timeIntervalSinceNow * -1)
                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnce() async {
        loading = true
        defer { loading = false }
        do {
            let a = try await client.fetchApproval(encounterId: encounterId)
            self.approval = a
            self.errorMessage = nil
        } catch RelayError.awaitingApproval {
            // expected — keep polling
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
