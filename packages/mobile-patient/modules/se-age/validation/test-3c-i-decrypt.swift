// 3c-i Mac validation driver.
// Concatenated with Bech32.swift + AgeFile.swift + AgeCrypto.swift at runtime.
// Runs on Sequoia (which has ~/.local/bin/age + age-plugin-se installed).

import Foundation
import CryptoKit

func fail(_ msg: String, line: Int = #line) -> Never {
    FileHandle.standardError.write("[FAIL @\(line)] \(msg)\n".data(using: .utf8)!)
    exit(1)
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

print("══════ 3c-i Mac validation ══════")

// ── 1. Generate test P-256 keypair (non-SE — pure CryptoKit) ──
let priv = P256.KeyAgreement.PrivateKey()
let pubCompressed = priv.publicKey.compressedRepresentation
print("[1] generated test P-256 keypair; pub \(pubCompressed.count)B prefix=0x\(String(pubCompressed[0], radix: 16))")

// ── 2. Encode pubkey as age1se1... recipient via our Bech32 ──
let recipient = Bech32.encode(hrp: "age1se", data: pubCompressed)
print("[2] recipient: \(recipient)")

// ── 3. Write known plaintext + invoke `age` to encrypt ──
let plaintext = Data("3c-i Mac validation — \(ISO8601DateFormatter().string(from: Date()))".utf8)
let tmpPlain = "/tmp/3ci-plain.txt"
let tmpAge = "/tmp/3ci.age"
try? FileManager.default.removeItem(atPath: tmpAge)
try plaintext.write(to: URL(fileURLWithPath: tmpPlain))

let home = ProcessInfo.processInfo.environment["HOME"]!
let ageBin = home + "/.local/bin/age"
let task = Process()
task.executableURL = URL(fileURLWithPath: ageBin)
task.arguments = ["-r", recipient, "-o", tmpAge, tmpPlain]
// age spawns age-plugin-se internally — need to inject ~/.local/bin into PATH.
var env = ProcessInfo.processInfo.environment
env["PATH"] = "\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
task.environment = env
let stderrPipe = Pipe()
task.standardError = stderrPipe
do {
    try task.run()
    task.waitUntilExit()
} catch {
    fail("could not spawn age: \(error)")
}
if task.terminationStatus != 0 {
    let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    fail("age failed (status=\(task.terminationStatus)): \(err)")
}
let ageBytes = try Data(contentsOf: URL(fileURLWithPath: tmpAge))
print("[3] age produced \(ageBytes.count)B encrypted file at \(tmpAge)")

// ── 4. Parse with our AgeFile.parse ──
let file: AgeFile
do { file = try AgeFileParser.parse(ageBytes) }
catch { fail("AgeFile.parse failed: \(error)") }
print("[4] parsed: \(file.header.stanzas.count) stanzas, header_for_hmac=\(file.header.rawBytesForHmac.count)B, mac=\(file.header.mac.count)B, body=\(file.bodyBytes.count)B")
for (i, s) in file.header.stanzas.enumerated() {
    print("    [\(i)] type='\(s.type)' args=\(s.args.count) body=\(s.body.count)B")
}

// ── 5. Find piv-p256 stanza, extract ephemeral pub ──
guard let stanza = file.header.stanzas.first(where: { $0.type == "piv-p256" }) else {
    fail("no piv-p256 stanza")
}
guard stanza.args.count == 2,
      let ephemeralPub = base64DecodeUnpadded(stanza.args[1]),
      ephemeralPub.count == 33 else {
    fail("invalid stanza args: count=\(stanza.args.count)")
}
print("[5] ephemeral pub (33B): \(hex(ephemeralPub))")

// ── 6. Compute shared secret (manually, mocking SE.performKeyAgreement) ──
let ephemeralPubKey: P256.KeyAgreement.PublicKey
do { ephemeralPubKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: ephemeralPub) }
catch { fail("could not parse ephemeral pub as P256: \(error)") }
let shared = try priv.sharedSecretFromKeyAgreement(with: ephemeralPubKey)
let sharedData = shared.withUnsafeBytes { Data($0) }
print("[6] ECDH shared secret (\(sharedData.count)B): \(hex(sharedData))")

// ── 7. Derive wrap key (HKDF) ──
let wrapKey = AgeCrypto.pivP256WrapKey(sharedSecret: sharedData, ephemeralPub: ephemeralPub, recipientPub: pubCompressed)
print("[7] wrap_key derived via HKDF-SHA256")

// ── 8. Unwrap file_key ──
let fileKey: Data
do { fileKey = try AgeCrypto.unwrapFileKey(wrapped: stanza.body, wrapKey: wrapKey) }
catch { fail("unwrapFileKey: \(error)") }
print("[8] file_key (\(fileKey.count)B): \(hex(fileKey))")

// ── 9. Verify header HMAC ──
do { try AgeCrypto.verifyHeaderHmac(file.header, fileKey: fileKey) }
catch { fail("verifyHeaderHmac: \(error)") }
print("[9] header HMAC verified")

// ── 10. Decrypt payload ──
let payloadKey = AgeCrypto.payloadKey(fileKey: fileKey, nonceSalt: file.nonceSalt)
let decrypted: Data
do { decrypted = try AgeCrypto.decryptSingleChunkPayload(ciphertext: file.ciphertext, payloadKey: payloadKey) }
catch { fail("decryptSingleChunkPayload: \(error)") }
print("[10] decrypted \(decrypted.count)B")
print("     text: '\(String(data: decrypted, encoding: .utf8) ?? "<binary>")'")

// ── 11. Assert plaintext match ──
guard decrypted == plaintext else {
    fail("MISMATCH\n     expected: \(hex(plaintext))\n     got:      \(hex(decrypted))")
}
print("══════ ✓✓✓ ROUND-TRIP MATCH ══════")
