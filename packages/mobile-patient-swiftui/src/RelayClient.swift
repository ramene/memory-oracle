// RelayClient.swift
//
// URLSession HTTP client + polling loop for the encounter-relay. The relay
// is the same Node service at packages/encounter-relay/ — patient app
// hits it via plain HTTP (the LAN-IP demo path requires NSAllowsArbitraryLoads
// in Info.plist; production swaps to https://verum.sh and drops the ATS exception).
//
// Wire format mirrors packages/encounter-relay/types.ts. JSON-LD @type
// fields kept verbatim for paper-figure friendliness.

import Foundation
import SwiftUI
import Combine

// MARK: - Wire format

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

struct PendingRequestsResponse: Codable {
    let requests: [EncounterRequest]
}

// MARK: - Configuration

enum RelayConfig {
    /// Compile-time default. Runtime override via UserDefaults key "relayBaseUrl".
    static let defaultBaseUrl = "http://192.168.100.5:8080"

    static var baseUrl: String {
        UserDefaults.standard.string(forKey: "relayBaseUrl") ?? defaultBaseUrl
    }
}

// MARK: - HTTP client

enum RelayError: LocalizedError {
    case invalidURL(String)
    case http(Int, String)
    case decode(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):      return "Invalid URL: \(s)"
        case .http(let code, let s):  return "HTTP \(code): \(s)"
        case .decode(let s):          return "Decode error: \(s)"
        case .network(let s):         return "Network error: \(s)"
        }
    }
}

struct RelayClient {
    let baseUrl: String

    init(baseUrl: String = RelayConfig.baseUrl) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    }

    func fetchPendingRequests(for patientRecipient: String) async throws -> [EncounterRequest] {
        guard var components = URLComponents(string: "\(baseUrl)/encounter") else {
            throw RelayError.invalidURL(baseUrl)
        }
        components.queryItems = [URLQueryItem(name: "for", value: patientRecipient)]
        guard let url = components.url else { throw RelayError.invalidURL(baseUrl) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RelayError.network("non-HTTP response") }
        guard http.statusCode == 200 else {
            throw RelayError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(PendingRequestsResponse.self, from: data).requests
        } catch {
            throw RelayError.decode(error.localizedDescription)
        }
    }

    func submitApproval(_ approval: EncounterApproval) async throws {
        guard let url = URL(string: "\(baseUrl)/encounter/\(approval.encounterId)/approval") else {
            throw RelayError.invalidURL(baseUrl)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(approval)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RelayError.network("non-HTTP response") }
        guard http.statusCode == 200 else {
            throw RelayError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
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
}

// MARK: - Foreground-only poller

@MainActor
final class PendingRequestsPoller: ObservableObject {
    @Published var requests: [EncounterRequest] = []
    @Published var loading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var relayReachable: Bool? = nil

    private let client: RelayClient
    private let patientRecipient: String
    private var pollingTask: Task<Void, Never>?
    private let pollIntervalNs: UInt64 = 5 * 1_000_000_000

    init(client: RelayClient = RelayClient(), patientRecipient: String) {
        self.client = client
        self.patientRecipient = patientRecipient
    }

    func start() {
        stop()
        Task { @MainActor in
            self.relayReachable = await client.ping()
        }
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                await fetchOnce()
                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func fetchOnce() async {
        loading = true
        defer { loading = false }
        do {
            requests = try await client.fetchPendingRequests(for: patientRecipient)
            errorMessage = nil
            relayReachable = true
        } catch {
            errorMessage = error.localizedDescription
            relayReachable = false
        }
    }
}
