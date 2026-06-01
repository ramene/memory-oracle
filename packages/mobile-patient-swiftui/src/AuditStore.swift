// AuditStore.swift
//
// Keychain-backed audit log. Last-100 ring buffer. Mirrors the Expo
// version's audit.js but uses Security framework directly (no
// expo-secure-store wrapper). In production this would also mirror to
// the memory-oracle audit endpoint for the HIPAA §164.526 trail.

import Foundation
import Security

struct AuditEntry: Codable, Identifiable {
    var id: String { ts }
    let ts: String                        // ISO-8601
    let event: String
    let encounterId: String?
    let clinicianName: String?
    let clinicianRecipientPrefix: String?
    let scopes: [String]?
    let expiresAt: String?
    let note: String?

    init(event: String,
         encounterId: String? = nil,
         clinicianName: String? = nil,
         clinicianRecipientPrefix: String? = nil,
         scopes: [String]? = nil,
         expiresAt: String? = nil,
         note: String? = nil) {
        self.ts = ISO8601DateFormatter().string(from: Date())
        self.event = event
        self.encounterId = encounterId
        self.clinicianName = clinicianName
        self.clinicianRecipientPrefix = clinicianRecipientPrefix
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.note = note
    }
}

enum AuditStore {
    private static let service = "ai.memoryoracle.patient.audit"
    private static let account = "log.v1"
    private static let maxEntries = 100

    static func append(_ entry: AuditEntry) {
        var log = read()
        log.append(entry)
        if log.count > maxEntries { log = Array(log.suffix(maxEntries)) }
        save(log)
    }

    static func read() -> [AuditEntry] {
        guard let data = loadRaw() else { return [] }
        return (try? JSONDecoder().decode([AuditEntry].self, from: data)) ?? []
    }

    static func clear() {
        save([])
    }

    // MARK: - Keychain helpers

    private static func save(_ log: [AuditEntry]) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadRaw() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
