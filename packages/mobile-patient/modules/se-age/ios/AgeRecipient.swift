import Foundation
import CryptoKit

// age-plugin-se recipient encoding.
// HRP "age1se", data = 33-byte compressed P-256 public key, bech32 (NOT bech32m).
// Wire-compatible with `age-plugin-se keygen` output.

let ageSeRecipientHRP = "age1se"

func encodeAgeSeRecipient(publicKey: P256.KeyAgreement.PublicKey) -> String {
  let compressed = publicKey.compressedRepresentation
  return Bech32.encode(hrp: ageSeRecipientHRP, data: compressed)
}

func decodeAgeSeRecipient(_ recipient: String) throws -> Data {
  let (hrp, data) = try Bech32.decode(recipient)
  guard hrp == ageSeRecipientHRP else {
    throw SeAgeError.invalidRecipient("expected HRP '\(ageSeRecipientHRP)', got '\(hrp)'")
  }
  guard data.count == 33 else {
    throw SeAgeError.invalidRecipient("expected 33-byte compressed P-256 pubkey, got \(data.count) bytes")
  }
  let prefix = data[data.startIndex]
  guard prefix == 0x02 || prefix == 0x03 else {
    throw SeAgeError.invalidRecipient("compressed point prefix must be 0x02 or 0x03, got 0x\(String(prefix, radix: 16))")
  }
  return data
}
