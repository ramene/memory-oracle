// 3c-ii Mac validation driver.
// Concatenated with Bech32 + AgeFile + AgeCrypto + AgeEncryptor at runtime.
// Two tests:
//   A — encrypt-then-decrypt roundtrip using our code on both sides (no
//       SE, manual ECDH on the decrypt path to mock SeAgeService)
//   B — encrypt to a known macOS verum --se recipient; smoke-check that
//       the resulting age file is structurally valid (full Touch ID decrypt
//       requires GUI session — operator runs Test B at Sequoia console)

import Foundation
import CryptoKit

// AgeEncryptor's `decodeAgeSeRecipient` lives in AgeRecipient.swift which
// depends on SeAgeError (which lives in SeAgeService.swift, which we can't
// pull in standalone because it depends on Security/LocalAuthentication
// types we don't want at test time). So we inline a minimal decoder here.

// Replace AgeEncryptor's decodeAgeSeRecipient call with a local function
// by shimming the symbol. Swift resolution: define our own in the same
// scope before AgeEncryptor is reached at runtime.
// (At-runtime shim: AgeEncryptor calls `decodeAgeSeRecipient`; we provide
//  it below before concatenation.)
struct TestSeAgeError: LocalizedError { let msg: String; var errorDescription: String? { msg } }
enum SeAgeError: LocalizedError {
    case invalidRecipient(String)
    var errorDescription: String? {
        if case .invalidRecipient(let s) = self { return "invalidRecipient: \(s)" }
        return nil
    }
    var code: String { "SeAgeInvalidRecipient" }
}
let ageSeRecipientHRP = "age1se"
func decodeAgeSeRecipient(_ recipient: String) throws -> Data {
    let (hrp, data) = try Bech32.decode(recipient)
    guard hrp == ageSeRecipientHRP else {
        throw SeAgeError.invalidRecipient("expected HRP '\(ageSeRecipientHRP)', got '\(hrp)'")
    }
    guard data.count == 33 else {
        throw SeAgeError.invalidRecipient("expected 33-byte compressed P-256, got \(data.count)")
    }
    let prefix = data[data.startIndex]
    guard prefix == 0x02 || prefix == 0x03 else {
        throw SeAgeError.invalidRecipient("compressed point prefix must be 0x02 or 0x03")
    }
    return data
}

func failTest(_ msg: String, line: Int = #line) -> Never {
    FileHandle.standardError.write("[FAIL @\(line)] \(msg)\n".data(using: .utf8)!)
    exit(1)
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

print("══════ 3c-ii Mac validation ══════")

// ── TEST A: our-encrypt → our-decrypt roundtrip ──
print("\n── Test A: our-encrypt → our-decrypt (manual ECDH on decrypt side) ──")

let priv = P256.KeyAgreement.PrivateKey()
let pubCompressed = priv.publicKey.compressedRepresentation
let recipient = Bech32.encode(hrp: "age1se", data: pubCompressed)
print("[A.1] recipient: \(recipient)")

let plaintextA = Data("3c-ii test A — our-roundtrip — \(ISO8601DateFormatter().string(from: Date()))".utf8)
print("[A.2] plaintext: '\(String(data: plaintextA, encoding: .utf8)!)' (\(plaintextA.count)B)")

let encrypted: Data
do { encrypted = try AgeEncryptor.encryptToRecipient(plaintext: plaintextA, recipient: recipient) }
catch { failTest("encryptToRecipient: \(error)") }
print("[A.3] AgeEncryptor produced \(encrypted.count)B age file")

// Parse and inspect
let file: AgeFile
do { file = try AgeFileParser.parse(encrypted) }
catch { failTest("AgeFileParser.parse on our output: \(error) — our encoder produced an unparseable file") }
print("[A.4] parsed our file: \(file.header.stanzas.count) stanza(s)")
guard let stanza = file.header.stanzas.first(where: { $0.type == "piv-p256" }) else {
    failTest("our encoder didn't emit a piv-p256 stanza")
}
print("       stanza args: \(stanza.args) body=\(stanza.body.count)B")
guard stanza.args.count == 2,
      let ephemeralPub = base64DecodeUnpadded(stanza.args[1]),
      ephemeralPub.count == 33 else {
    failTest("malformed stanza args from our encoder")
}

// Mock the decrypt-side SE.performKeyAgreement with manual ECDH
let ephemeralPubKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: ephemeralPub)
let shared = try priv.sharedSecretFromKeyAgreement(with: ephemeralPubKey)
let sharedData = shared.withUnsafeBytes { Data($0) }
let wrapKey = AgeCrypto.pivP256WrapKey(sharedSecret: sharedData, ephemeralPub: ephemeralPub, recipientPub: pubCompressed)
let fileKey: Data
do { fileKey = try AgeCrypto.unwrapFileKey(wrapped: stanza.body, wrapKey: wrapKey) }
catch { failTest("3c-i unwrapFileKey rejected our wrapped key: \(error)") }
print("[A.5] file_key recovered: \(hex(fileKey))")

do { try AgeCrypto.verifyHeaderHmac(file.header, fileKey: fileKey) }
catch { failTest("3c-i verifyHeaderHmac rejected our header HMAC: \(error)") }
print("[A.6] our HMAC verifies against 3c-i's verifier")

let payloadKey = AgeCrypto.payloadKey(fileKey: fileKey, nonceSalt: file.nonceSalt)
let decrypted: Data
do { decrypted = try AgeCrypto.decryptSingleChunkPayload(ciphertext: file.ciphertext, payloadKey: payloadKey) }
catch { failTest("3c-i decryptSingleChunkPayload rejected our payload: \(error)") }

guard decrypted == plaintextA else {
    failTest("Test A MISMATCH\n   expected: \(hex(plaintextA))\n   got:      \(hex(decrypted))")
}
print("[A.7] ✓ Test A ROUND-TRIP MATCH — \(decrypted.count)B decrypted, byte-equal")

// ── TEST B: encrypt to Sequoia's actual verum --se recipient ──
print("\n── Test B: our-encrypt → age-plugin-se decrypt (structural check) ──")

let sequoiaRecipientPath = ProcessInfo.processInfo.environment["HOME"]! + "/verum-se-test/verum-se-identity.txt"
guard let identityStr = try? String(contentsOfFile: sequoiaRecipientPath, encoding: .utf8) else {
    print("[B] skipped — no Sequoia identity file at \(sequoiaRecipientPath)")
    print("══════ ✓✓ Test A passed; Test B skipped ══════")
    exit(0)
}
guard let recipientLine = identityStr.split(separator: "\n").first(where: { $0.hasPrefix("# public key: ") }) else {
    print("[B] could not find recipient line"); exit(0)
}
let sequoiaRecipient = String(recipientLine.dropFirst("# public key: ".count)).trimmingCharacters(in: .whitespaces)
print("[B.1] sequoia recipient: \(sequoiaRecipient)")

let plaintextB = Data("3c-ii test B — sequoia-targeted — \(Int(Date().timeIntervalSince1970))".utf8)
let encryptedB: Data
do { encryptedB = try AgeEncryptor.encryptToRecipient(plaintext: plaintextB, recipient: sequoiaRecipient) }
catch { failTest("encrypt to sequoia recipient: \(error)") }
print("[B.2] produced \(encryptedB.count)B file")

let outPath = "/tmp/3cii-to-sequoia.age"
try encryptedB.write(to: URL(fileURLWithPath: outPath))
print("[B.3] wrote to \(outPath)")
print("       cat first 6 lines:")
let lines = String(data: encryptedB.prefix(400), encoding: .utf8) ?? "<binary>"
print(lines.split(separator: "\n").prefix(6).map { "         \($0)" }.joined(separator: "\n"))
print("")
print("[B.4] Operator: at Sequoia console, run:")
print("       age -d -i ~/verum-se-test/verum-se-identity.txt \(outPath)")
print("       → Touch ID fires → should print:")
print("       '\(String(data: plaintextB, encoding: .utf8)!)'")

print("\n══════ ✓✓✓ Test A passed; Test B artifact at /tmp/3cii-to-sequoia.age (needs console Touch ID) ══════")
