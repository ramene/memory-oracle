// ApproveHandler.swift
//
// Patient's step ⑤: for each requested scope, generate a fresh 16-byte
// session key, wrap it via SeAgeService.encryptToRecipient() (3c-ii) to
// the clinician's age recipient, base64-encode, and POST an
// EncounterApproval to the relay.
//
// No Face ID fires here — encryption only uses the clinician's public
// key + an ephemeral CryptoKit keypair (no SE access). Face ID gates
// happen at SE-bound private-key operations, which encryption is not.
// The CONSENT UI is what enforces "user actually agreed"; this function
// is purely the crypto + network glue invoked after that user input.

import Foundation
import Security

enum ApproveError: LocalizedError {
    case randomFailure(OSStatus)
    case encryptFailure(String)
    case relayFailure(String)

    var errorDescription: String? {
        switch self {
        case .randomFailure(let s): return "SecRandomCopyBytes failed (\(s))"
        case .encryptFailure(let s): return "Encrypt to recipient failed: \(s)"
        case .relayFailure(let s):   return "Relay submission failed: \(s)"
        }
    }
}

enum ApproveHandler {

    /// Approves the encounter — generates per-scope session keys, encrypts
    /// to clinician, POSTs, audit-logs. Returns the submitted approval.
    static func approve(_ request: EncounterRequest,
                        client: RelayClient = RelayClient()) async throws -> EncounterApproval {

        // Per-scope session keys + wraps.
        var wrappedKeys: [String: String] = [:]
        for scope in request.requestedScopes {
            let sessionKey = try randomBytes(16)
            let wrappedData: Data
            do {
                wrappedData = try AgeEncryptor.encryptToRecipient(
                    plaintext: sessionKey,
                    recipient: request.clinicianRecipient
                )
            } catch {
                throw ApproveError.encryptFailure(error.localizedDescription)
            }
            wrappedKeys[scope] = wrappedData.base64EncodedString()
        }

        // Build + submit approval.
        let expiresAt = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(TimeInterval(request.ttlSeconds))
        )
        let approval = EncounterApproval(
            type: "EncounterApproval",
            encounterId: request.encounterId,
            wrappedKeys: wrappedKeys,
            expiresAt: expiresAt,
            auditEntryId: nil
        )

        do {
            try await client.submitApproval(approval)
        } catch {
            throw ApproveError.relayFailure(error.localizedDescription)
        }

        AuditStore.append(AuditEntry(
            event: "encounter_approved",
            encounterId: request.encounterId,
            clinicianName: request.clinicianName,
            clinicianRecipientPrefix: String(request.clinicianRecipient.prefix(20)),
            scopes: request.requestedScopes,
            expiresAt: expiresAt
        ))

        return approval
    }

    /// Denies the encounter — audit-only; the relay record expires naturally.
    static func deny(_ request: EncounterRequest) {
        AuditStore.append(AuditEntry(
            event: "encounter_denied",
            encounterId: request.encounterId,
            clinicianName: request.clinicianName,
            scopes: request.requestedScopes
        ))
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) throws -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { ptr -> OSStatus in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ApproveError.randomFailure(status)
        }
        return d
    }
}
