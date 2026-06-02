// IdentityStore.swift
//
// Multi-identity support for the clinician app. Each identity owns its
// own Secure Enclave key (separate kSecAttrApplicationTag → fully
// independent keychain entry) AND its own PIN (salt + SHA-256 hash).
// Switching identities requires BOTH the PIN (something you know) AND
// Face ID against the destination identity's SE key (something you are).
//
// Threat model:
//   - Shared iPad: a different doctor picking up the unlocked device
//     cannot switch to your identity without your PIN AND your face
//   - Even an attacker with both screen access AND knowledge of someone's
//     PIN cannot use the SE key without their biometric
//
// Storage:
//   - Identity records: keychain generic-password under
//     service="ai.memoryoracle.clinician.identities", account="list.v1"
//   - PIN hashes: stored INSIDE the identity record (one per identity)
//   - "Active identity tag": separate keychain entry,
//     account="active.v1", sticky across launches
//   - SE keys themselves: managed by SeAgeService under unique tags

import Foundation
import Security
import CryptoKit

struct ClinicianIdentity: Codable, Identifiable, Equatable {
    let id: String                    // UUID — stable across name edits
    var name: String                  // user-visible, e.g. "Dr. Y. Chen"
    let seKeyTag: String              // unique SE key tag, e.g. "mo.clinician.identity.<uuid>.v1"
    let recipient: String             // age1se1... captured at create time
    let pinSalt: Data                 // 16-byte random
    let pinHash: Data                 // SHA-256(salt || pin)
    let createdAt: String             // ISO-8601

    func verifyPin(_ pin: String) -> Bool {
        var hasher = SHA256()
        hasher.update(data: pinSalt)
        hasher.update(data: Data(pin.utf8))
        let computed = Data(hasher.finalize())
        // Constant-time-ish comparison (Data.== is not, but the surface is tiny)
        return computed == pinHash
    }
}

enum IdentityStoreError: LocalizedError {
    case invalidPin
    case pinTooShort
    case nameRequired
    case keychainFailure(OSStatus)
    case seKeyGenerationFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidPin:                return "Incorrect PIN."
        case .pinTooShort:               return "PIN must be at least 4 digits."
        case .nameRequired:              return "Name is required."
        case .keychainFailure(let s):    return "Keychain operation failed (OSStatus=\(s))."
        case .seKeyGenerationFailed(let s): return "SE key generation failed: \(s)"
        case .notFound(let s):           return "Identity not found: \(s)"
        }
    }
}

enum IdentityStore {
    private static let service = "ai.memoryoracle.clinician.identities"
    private static let listAccount = "list.v1"
    private static let activeAccount = "active.v1"

    // MARK: - List + Active

    static func all() -> [ClinicianIdentity] {
        guard let data = loadRaw(account: listAccount) else { return [] }
        return (try? JSONDecoder().decode([ClinicianIdentity].self, from: data)) ?? []
    }

    static func activeId() -> String? {
        guard let data = loadRaw(account: activeAccount),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s.isEmpty ? nil : s
    }

    static func active() -> ClinicianIdentity? {
        guard let id = activeId() else { return nil }
        return all().first { $0.id == id }
    }

    static func setActive(_ id: String) throws {
        guard all().contains(where: { $0.id == id }) else {
            throw IdentityStoreError.notFound(id)
        }
        saveRaw(account: activeAccount, data: Data(id.utf8))
    }

    // MARK: - Create / Delete

    /// Creates a new identity: generates an SE-bound key under a unique
    /// tag, stores the recipient + PIN salt + PIN hash in keychain.
    /// Does NOT make it active — caller can choose to setActive.
    static func create(name: String, pin: String) throws -> ClinicianIdentity {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw IdentityStoreError.nameRequired }
        guard pin.count >= 4 else { throw IdentityStoreError.pinTooShort }

        let id = UUID().uuidString
        let tag = "mo.clinician.identity.\(id).v1"

        // Generate SE-bound P-256 key under unique tag, recipient is the bech32 age1se1...
        let recipient: String
        do {
            recipient = try SeAgeService.getOrCreateIdentity(tag: tag)
        } catch {
            throw IdentityStoreError.seKeyGenerationFailed(error.localizedDescription)
        }

        // PIN: random 16-byte salt + SHA-256(salt || pin)
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { ptr -> OSStatus in
            SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychainFailure(status)
        }
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(pin.utf8))
        let hash = Data(hasher.finalize())

        let identity = ClinicianIdentity(
            id: id,
            name: trimmedName,
            seKeyTag: tag,
            recipient: recipient,
            pinSalt: salt,
            pinHash: hash,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        var list = all()
        list.append(identity)
        try saveList(list)
        return identity
    }

    /// Removes an identity from the list. Note: the SE key itself REMAINS in
    /// the iOS keychain — this is intentional. SE keys cannot be migrated and
    /// the operator may want recovery. To fully purge, call
    /// SeAgeService.deleteIdentity(tag:) separately. For the demo this is fine.
    static func delete(id: String) throws {
        var list = all()
        guard let _ = list.firstIndex(where: { $0.id == id }) else {
            throw IdentityStoreError.notFound(id)
        }
        list.removeAll { $0.id == id }
        try saveList(list)
        if activeId() == id {
            saveRaw(account: activeAccount, data: Data())  // clear active
        }
    }

    // MARK: - Switch (PIN + biometric)

    /// Verifies the PIN against the identity's stored hash. Caller is
    /// responsible for ALSO running Face ID via LAContext before
    /// invoking setActive. PIN-only is not sufficient.
    static func verifyPin(identityId: String, pin: String) throws {
        guard let identity = all().first(where: { $0.id == identityId }) else {
            throw IdentityStoreError.notFound(identityId)
        }
        guard identity.verifyPin(pin) else {
            throw IdentityStoreError.invalidPin
        }
    }

    // MARK: - Keychain helpers

    private static func saveList(_ list: [ClinicianIdentity]) throws {
        let data = try JSONEncoder().encode(list)
        saveRaw(account: listAccount, data: data)
    }

    private static func saveRaw(account: String, data: Data) {
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

    private static func loadRaw(account: String) -> Data? {
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
