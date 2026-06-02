import Foundation
import CryptoKit

// age + piv-p256 cryptographic helpers, separated from the SE wiring so
// the math can be Mac-tested with regular CryptoKit P-256 keys (no
// Secure Enclave required for unit-level validation).
//
// piv-p256 wrap derivation matches age-plugin-yubikey / age-plugin-se:
//
//   ikm        = ECDH(my_priv, ephemeral_pub)                              (32B)
//   salt       = ephemeral_pub_compressed || my_pub_compressed             (66B)
//   info       = "piv-p256"                                                (8B)
//   wrap_key   = HKDF-SHA256-Extract-then-Expand(ikm, salt, info, L=32)    (32B)
//
//   file_key   = ChaCha20-Poly1305.open(wrapped, key=wrap_key, nonce=0)    (16B)
//
//   header_mac_key = HKDF-SHA256(file_key, salt=empty, info="header", L=32)
//   header_mac    = HMAC-SHA256(header_mac_key, raw_bytes_for_hmac)        (32B)
//
//   payload_key = HKDF-SHA256(file_key, salt=nonce_salt(16B), info="payload", L=32)
//
//   For each 64KB chunk:
//     nonce = 11-byte big-endian counter || 1-byte last-chunk flag
//     plaintext_chunk = ChaCha20-Poly1305.open(ciphertext_chunk, payload_key, nonce, "")

enum AgeCryptoError: LocalizedError {
    case wrapKeyMismatch
    case headerMacMismatch
    case multiChunkNotSupported(Int)
    case truncatedPayload
    case payloadAuthFailed

    var errorDescription: String? {
        switch self {
        case .wrapKeyMismatch:           return "Wrap-key ChaCha20-Poly1305 auth failed (wrong identity)"
        case .headerMacMismatch:         return "age header HMAC verification failed (file_key recovered but does not match header)"
        case .multiChunkNotSupported(let n): return "Multi-chunk payloads not yet supported (got \(n) chunks). 3c-i ships single-chunk decryption for the patient demo; multi-chunk lands when records exceed 64KB."
        case .truncatedPayload:          return "Truncated payload — fewer than 16 bytes after nonce_salt"
        case .payloadAuthFailed:         return "Payload ChaCha20-Poly1305 auth failed"
        }
    }
}

enum AgeCrypto {

    /// HKDF-SHA256(ikm=sharedSecret, salt=ephemeralPub||recipientPub, info="piv-p256", L=32).
    static func pivP256WrapKey(sharedSecret: Data, ephemeralPub: Data, recipientPub: Data) -> SymmetricKey {
        var salt = Data()
        salt.append(ephemeralPub)
        salt.append(recipientPub)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: Data("piv-p256".utf8),
            outputByteCount: 32
        )
    }

    /// Unwraps the 32-byte (16B ciphertext + 16B Poly1305 tag) wrapped file
    /// key using ChaCha20-Poly1305 with an all-zero 96-bit nonce.
    static func unwrapFileKey(wrapped: Data, wrapKey: SymmetricKey) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
        guard wrapped.count == 32 else {
            throw AgeCryptoError.wrapKeyMismatch
        }
        let ciphertext = wrapped.prefix(16)
        let tag = wrapped.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let pt = try ChaChaPoly.open(box, using: wrapKey)
            return pt
        } catch {
            throw AgeCryptoError.wrapKeyMismatch
        }
    }

    /// Verifies the `--- <MAC>` header HMAC against the recovered file key.
    static func verifyHeaderHmac(_ header: AgeHeader, fileKey: Data) throws {
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: fileKey),
            salt: Data(),
            info: Data("header".utf8),
            outputByteCount: 32
        )
        let computed = HMAC<SHA256>.authenticationCode(for: header.rawBytesForHmac, using: macKey)
        let expected = Data(header.mac)
        if Data(computed) != expected {
            throw AgeCryptoError.headerMacMismatch
        }
    }

    /// HKDF-SHA256(ikm=fileKey, salt=nonceSalt, info="payload", L=32).
    static func payloadKey(fileKey: Data, nonceSalt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: fileKey),
            salt: nonceSalt,
            info: Data("payload".utf8),
            outputByteCount: 32
        )
    }

    /// Decrypts a SINGLE-chunk payload. The patient flow ships records
    /// under 64KB, so single-chunk is sufficient. Multi-chunk lands
    /// later when records grow.
    static func decryptSingleChunkPayload(ciphertext: Data, payloadKey: SymmetricKey) throws -> Data {
        // Single-chunk size cap: 64 KiB plaintext + 16 byte tag.
        guard ciphertext.count >= 16 else { throw AgeCryptoError.truncatedPayload }
        let maxChunk = 64 * 1024 + 16
        if ciphertext.count > maxChunk {
            // estimate number of chunks for a clearer error
            let approx = (ciphertext.count + maxChunk - 1) / maxChunk
            throw AgeCryptoError.multiChunkNotSupported(approx)
        }
        // Nonce: 11 zero bytes + 0x01 (last-chunk flag).
        var nonceBytes = Data(repeating: 0, count: 12)
        nonceBytes[11] = 0x01
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            return try ChaChaPoly.open(box, using: payloadKey)
        } catch {
            throw AgeCryptoError.payloadAuthFailed
        }
    }
}
