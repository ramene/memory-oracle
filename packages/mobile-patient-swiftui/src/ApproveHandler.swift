// ApproveHandler.swift
//
// Patient's step ⑤: gate on Face ID, then for each requested scope
// generate a fresh 16-byte session key, wrap it via
// SeAgeService.encryptToRecipient() (3c-ii) to the clinician's age
// recipient, base64-encode, and POST an EncounterApproval to the relay.
//
// FACE ID DESIGN NOTE: cryptographically, encryption only requires the
// clinician's public key + an ephemeral CryptoKit keypair — no SE access.
// But the LNCS §7.4 paper figure depicts the Face ID prompt AS the
// patient's consent moment, and the demo's whole point is "patient
// consent IS the Face ID gate." So we explicitly gate via
// LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)
// BEFORE the encryption runs, even though the crypto itself doesn't
// need to touch the Secure Enclave private key. User-presence enforcement
// is a separate concern from cryptographic key custody.

import Foundation
import Security
import LocalAuthentication

enum ApproveError: LocalizedError {
    case faceIdUnavailable(String)
    case faceIdCancelled
    case faceIdFailed(String)
    case randomFailure(OSStatus)
    case encryptFailure(String)
    case relayFailure(String)

    var errorDescription: String? {
        switch self {
        case .faceIdUnavailable(let s): return "Face ID unavailable: \(s)"
        case .faceIdCancelled:          return "Consent cancelled — Face ID dismissed"
        case .faceIdFailed(let s):      return "Face ID failed: \(s)"
        case .randomFailure(let s):     return "SecRandomCopyBytes failed (\(s))"
        case .encryptFailure(let s):    return "Encrypt to recipient failed: \(s)"
        case .relayFailure(let s):      return "Relay submission failed: \(s)"
        }
    }
}

enum ApproveHandler {

    /// Approves the encounter — Face ID gate → generates per-scope session
    /// keys → encrypts to clinician → POSTs → audit-logs. Returns the
    /// submitted approval.
    static func approve(_ request: EncounterRequest,
                        client: RelayClient = RelayClient()) async throws -> EncounterApproval {

        // ── Face ID gate (the paper's consent moment) ──
        let context = LAContext()
        var canEvalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canEvalError) else {
            throw ApproveError.faceIdUnavailable(canEvalError?.localizedDescription ?? "no biometric available")
        }
        let scopesList = request.requestedScopes.joined(separator: ", ")
        let ttlMin = max(1, request.ttlSeconds / 60)
        let reason = "Approve \(request.clinicianName) to access \(scopesList) for \(ttlMin) min"
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            guard success else { throw ApproveError.faceIdCancelled }
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .userFallback, .systemCancel, .appCancel:
                AuditStore.append(AuditEntry(
                    event: "encounter_face_id_cancelled",
                    encounterId: request.encounterId,
                    clinicianName: request.clinicianName,
                    scopes: request.requestedScopes
                ))
                throw ApproveError.faceIdCancelled
            default:
                throw ApproveError.faceIdFailed(e.localizedDescription)
            }
        } catch {
            throw ApproveError.faceIdFailed(error.localizedDescription)
        }

        // ── Past the gate: do the actual encryption + submit ──
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
