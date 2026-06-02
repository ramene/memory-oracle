// DecryptHandler.swift
//
// Clinician's step ⑧: receive EncounterApproval from relay, for each
// wrappedKey call SeAgeService.decryptAgeFile() (3c-i) which fires
// Face ID on THIS device's SE, recover the per-scope session key,
// then render the record content (mocked for the demo).
//
// In production: session key would unwrap the patient's at-rest
// encrypted record from a backend store. For the LNCS §7.4 demo, the
// recovery of the session key (cryptographic proof of approval) is the
// event the paper anchors on; the rendered content is illustrative
// (MockRecords).

import Foundation

struct DecryptedScope: Identifiable {
    var id: String { scope }
    let scope: String
    let sessionKeyHex: String         // proof artifact for the paper figure
    let recordText: String            // mocked illustrative content
}

enum DecryptError: LocalizedError {
    case base64Failure(String)
    case decryptFailure(String, Error)

    var errorDescription: String? {
        switch self {
        case .base64Failure(let scope):       return "Wrapped key for '\(scope)' is not valid base64"
        case .decryptFailure(let scope, let e): return "Decrypt failed for '\(scope)': \(e.localizedDescription)"
        }
    }
}

enum DecryptHandler {
    /// Iterates wrappedKeys → decrypts each via SE (Face ID fires ONCE on
    /// the first scope; iOS caches the LAContext authentication for the
    /// short window — subsequent scopes use it without re-prompting).
    static func decryptAll(approval: EncounterApproval,
                           clinicianKeyTag: String) async throws -> [DecryptedScope] {
        var results: [DecryptedScope] = []
        for (scope, wrappedB64) in approval.wrappedKeys {
            guard let wrapped = Data(base64Encoded: wrappedB64) else {
                throw DecryptError.base64Failure(scope)
            }
            let reason = "Decrypt session key for '\(scope)'"
            do {
                let sessionKey = try SeAgeService.decryptAgeFile(
                    tag: clinicianKeyTag,
                    ageBytes: wrapped,
                    reason: reason
                )
                let hex = sessionKey.map { String(format: "%02x", $0) }.joined()
                results.append(DecryptedScope(
                    scope: scope,
                    sessionKeyHex: hex,
                    recordText: MockRecords.render(scope: scope)
                ))
            } catch {
                throw DecryptError.decryptFailure(scope, error)
            }
        }
        // Sort for stable display order: alphabetical
        return results.sorted { $0.scope < $1.scope }
    }
}
