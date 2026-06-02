// AuditStore.swift  (clinician side — same pattern as patient app)

import Foundation
import Security

struct AuditEntry: Codable, Identifiable {
    var id: String { ts }
    let ts: String
    let event: String
    let encounterId: String?
    let patientRecipientPrefix: String?
    let scopes: [String]?
    let expiresAt: String?
    let note: String?

    init(event: String,
         encounterId: String? = nil,
         patientRecipientPrefix: String? = nil,
         scopes: [String]? = nil,
         expiresAt: String? = nil,
         note: String? = nil) {
        self.ts = ISO8601DateFormatter().string(from: Date())
        self.event = event
        self.encounterId = encounterId
        self.patientRecipientPrefix = patientRecipientPrefix
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.note = note
    }
}

enum AuditStore {
    private static let service = "ai.memoryoracle.clinician.audit"
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
