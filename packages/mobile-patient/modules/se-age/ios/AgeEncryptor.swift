import Foundation
import CryptoKit
import Security

// age v1 ENCRYPTION for piv-p256 recipients (mirror of AgeCrypto.swift's
// decryption helpers). Single-chunk only (≤64KB plaintext) for the
// patient-flow use case — multi-chunk lands later when records grow.
//
// Producing wire format identical to age-plugin-se output. The encrypter
// does NOT need a Secure Enclave key — encryption uses only the public
// recipient + an ephemeral keypair. Patient app calls this in step ⑤ to
// wrap a session key TO the clinician's recipient.

enum AgeEncryptorError: LocalizedError {
    case payloadTooLarge(Int)
    case randomBytesFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let n): return "Plaintext is \(n) bytes; single-chunk encryption caps at 64KB. Multi-chunk lands later."
        case .randomBytesFailed(let s): return "SecRandomCopyBytes failed: OSStatus \(s)"
        }
    }
}

enum AgeEncryptor {

    /// Encrypts `plaintext` to a single age1se1... recipient. Returns
    /// a valid age v1 file (suitable for `age -d` on the receiving side
    /// if they hold the matching SE private key).
    static func encryptToRecipient(plaintext: Data, recipient: String) throws -> Data {
        guard plaintext.count <= 64 * 1024 else {
            throw AgeEncryptorError.payloadTooLarge(plaintext.count)
        }

        let recipientPub = try decodeAgeSeRecipient(recipient)
        let recipientKey: P256.KeyAgreement.PublicKey
        do {
            recipientKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: recipientPub)
        } catch {
            throw SeAgeError.invalidRecipient("compressed point did not decode as a valid P-256 public key")
        }

        // ── 1. Fresh ephemeral keypair (regular CryptoKit, NOT SE) ──
        let ephemeralPriv = P256.KeyAgreement.PrivateKey()
        let ephemeralPub = ephemeralPriv.publicKey.compressedRepresentation

        // ── 2. ECDH → shared secret ──
        let shared = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientKey)
        let sharedData = shared.withUnsafeBytes { Data($0) }

        // ── 3. Derive wrap_key (same recipe as decrypt — must be symmetric) ──
        let wrapKey = AgeCrypto.pivP256WrapKey(
            sharedSecret: sharedData, ephemeralPub: ephemeralPub, recipientPub: recipientPub)

        // ── 4. Generate fresh 16-byte file_key ──
        let fileKey = try randomBytes(16)

        // ── 5. Wrap file_key (ChaCha20-Poly1305, all-zero nonce) ──
        let zeroNonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
        let wrappedSealed = try ChaChaPoly.seal(fileKey, using: wrapKey, nonce: zeroNonce)
        let wrappedBody = wrappedSealed.ciphertext + wrappedSealed.tag   // 16 + 16 = 32 bytes

        // ── 6. Recipient fingerprint (first 4 bytes of SHA-256 over the
        //      compressed recipient pubkey — matches age-plugin-se /
        //      age-plugin-yubikey convention; lets the decrypter quickly
        //      filter stanzas without trying ECDH on every one) ──
        let fingerprint = Data(SHA256.hash(data: recipientPub)).prefix(4)

        // ── 7. Build stanza ──
        let stanza = "-> piv-p256 \(base64EncodeUnpadded(fingerprint)) \(base64EncodeUnpadded(ephemeralPub))\n\(wrapStanzaBody(base64EncodeUnpadded(wrappedBody)))"

        // ── 8. Header bytes for HMAC (intro through "---" exclusive of space + MAC + LF) ──
        let headerForHmacText = "age-encryption.org/v1\n\(stanza)\n---"
        let headerForHmac = Data(headerForHmacText.utf8)

        // ── 9. HMAC the header ──
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: fileKey),
            salt: Data(),
            info: Data("header".utf8),
            outputByteCount: 32
        )
        let mac = Data(HMAC<SHA256>.authenticationCode(for: headerForHmac, using: macKey))

        // ── 10. Generate nonce_salt + derive payload_key ──
        let nonceSalt = try randomBytes(16)
        let payloadKey = AgeCrypto.payloadKey(fileKey: fileKey, nonceSalt: nonceSalt)

        // ── 11. Encrypt payload (single-chunk: nonce = 11×0x00 || 0x01) ──
        var nonceBytes = Data(repeating: 0, count: 12)
        nonceBytes[11] = 0x01
        let payloadNonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let sealed = try ChaChaPoly.seal(plaintext, using: payloadKey, nonce: payloadNonce)
        let payloadCipher = sealed.ciphertext + sealed.tag

        // ── 12. Assemble: header + " <mac_b64>\n" + nonce_salt + payload ──
        var output = headerForHmac
        output.append(Data(" \(base64EncodeUnpadded(mac))\n".utf8))
        output.append(nonceSalt)
        output.append(payloadCipher)
        return output
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) throws -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { ptr -> OSStatus in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AgeEncryptorError.randomBytesFailed(status)
        }
        return d
    }

    /// age wraps stanza-body base64 at 64 columns with bare newlines.
    private static func wrapStanzaBody(_ b64: String) -> String {
        let cols = 64
        guard b64.count > cols else { return b64 }
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let next = b64.index(i, offsetBy: cols, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<next]))
            i = next
        }
        return lines.joined(separator: "\n")
    }
}
