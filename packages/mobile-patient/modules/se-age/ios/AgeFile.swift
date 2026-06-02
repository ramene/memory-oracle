import Foundation

// age v1 file-format parser (https://age-encryption.org/v1)
//
// Pure structural parsing — no cryptography. Splits an age file into:
//   - header (stanzas + MAC + the exact bytes that go into HMAC verification)
//   - body (nonce_salt + chunked ChaCha20-Poly1305 ciphertext)
//
// Note on stanza body line-wrapping: age wraps stanza bodies at 64 columns
// with bare-newline continuations. This parser concatenates wrapped lines
// before base64-decoding.

struct AgeStanza {
    let type: String       // e.g. "piv-p256"
    let args: [String]     // unpadded canonical base64 strings
    let body: Data         // base64-decoded
}

struct AgeHeader {
    let stanzas: [AgeStanza]
    let mac: Data
    /// Exact bytes the spec requires for HMAC: everything from
    /// `age-encryption.org/v1\n` through the `---` marker (including the
    /// single space after `---`), but NOT the MAC's base64 or any trailing
    /// newline. age spec §"Header MAC".
    let rawBytesForHmac: Data
}

struct AgeFile {
    let header: AgeHeader
    /// Everything after the header's terminating newline: first 16 bytes
    /// are the payload nonce_salt, the rest is the chunked ciphertext.
    let bodyBytes: Data

    var nonceSalt: Data { bodyBytes.prefix(16) }
    var ciphertext: Data { bodyBytes.dropFirst(16) }
}

enum AgeFileError: LocalizedError {
    case invalidVersion(String)
    case malformedStanza(String)
    case missingMacLine
    case invalidBase64(String)
    case unexpectedEnd

    var errorDescription: String? {
        switch self {
        case .invalidVersion(let s): return "Unsupported age version line: \(s)"
        case .malformedStanza(let s): return "Malformed age stanza: \(s)"
        case .missingMacLine:        return "Missing `--- <MAC>` header terminator"
        case .invalidBase64(let s):  return "Invalid age base64: \(s)"
        case .unexpectedEnd:         return "Unexpected end of age file"
        }
    }
}

enum AgeFileParser {
    static func parse(_ data: Data) throws -> AgeFile {
        // Find the `---` line terminator manually so we can capture the
        // exact pre-newline byte range for HMAC. age headers are ASCII
        // until the body begins.
        guard let macLineStart = findMacLineStart(in: data) else {
            throw AgeFileError.missingMacLine
        }

        // age v1 spec: HMAC input ends at `---` exactly (3 chars, NO trailing
        // space, NO base64 MAC, NO newline). The space-then-MAC-then-newline
        // follow but are excluded from authentication.
        let hmacEnd = macLineStart + 3       // "---"
        let macB64Start = macLineStart + 4   // skip the single space
        guard macB64Start <= data.count else { throw AgeFileError.unexpectedEnd }
        let rawForHmac = data.subdata(in: 0 ..< hmacEnd)

        guard let macLineEnd = data.firstIndex(of: 0x0a, after: macB64Start) else {
            throw AgeFileError.unexpectedEnd
        }
        let macB64 = String(data: data.subdata(in: macB64Start ..< macLineEnd), encoding: .utf8) ?? ""
        guard let mac = base64DecodeUnpadded(macB64), mac.count == 32 else {
            throw AgeFileError.invalidBase64("MAC: '\(macB64)'")
        }

        let bodyStart = macLineEnd + 1   // skip the newline after the MAC
        let bodyBytes = bodyStart < data.count ? data.subdata(in: bodyStart ..< data.count) : Data()

        // Parse the stanzas from the header text (everything before `---`).
        let headerBytes = data.subdata(in: 0 ..< macLineStart)
        guard let headerStr = String(data: headerBytes, encoding: .utf8) else {
            throw AgeFileError.malformedStanza("non-UTF8 header bytes")
        }
        let stanzas = try parseStanzas(headerText: headerStr)

        return AgeFile(
            header: AgeHeader(stanzas: stanzas, mac: mac, rawBytesForHmac: rawForHmac),
            bodyBytes: bodyBytes
        )
    }

    // MARK: - Internal

    /// Returns the byte offset of `---` at the start of a line (i.e. the
    /// MAC terminator line). Returns nil if not found.
    private static func findMacLineStart(in data: Data) -> Int? {
        var i = 0
        let end = data.count
        while i < end {
            let lineStart = i
            // advance to end-of-line
            while i < end && data[i] != 0x0a { i += 1 }
            // line is data[lineStart ..< i]
            if i - lineStart >= 4 &&
                data[lineStart] == 0x2d && data[lineStart + 1] == 0x2d && data[lineStart + 2] == 0x2d &&
                data[lineStart + 3] == 0x20 {
                return lineStart
            }
            i += 1   // skip the LF
        }
        return nil
    }

    private static func parseStanzas(headerText: String) throws -> [AgeStanza] {
        var lines = headerText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { throw AgeFileError.unexpectedEnd }
        guard first == "age-encryption.org/v1" else {
            throw AgeFileError.invalidVersion(first)
        }
        lines.removeFirst()

        var stanzas: [AgeStanza] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            guard line.hasPrefix("-> ") else {
                throw AgeFileError.malformedStanza("expected '-> ' prefix, got: '\(line)'")
            }
            let tokens = line.dropFirst(3).split(separator: " ").map(String.init)
            guard let type = tokens.first else {
                throw AgeFileError.malformedStanza("stanza header empty")
            }
            let args = Array(tokens.dropFirst())
            // Body: subsequent lines NOT starting with "-> " until the
            // next stanza header or end. age spec wraps stanza bodies at
            // 64 columns; concatenate all continuation lines.
            i += 1
            var bodyB64 = ""
            while i < lines.count {
                let next = lines[i]
                if next.hasPrefix("-> ") || next.isEmpty { break }
                bodyB64 += next
                i += 1
            }
            guard let body = base64DecodeUnpadded(bodyB64) else {
                throw AgeFileError.invalidBase64("stanza body: '\(bodyB64)'")
            }
            stanzas.append(AgeStanza(type: type, args: args, body: body))
        }
        return stanzas
    }
}

// MARK: - Canonical base64 (unpadded) helper

func base64DecodeUnpadded(_ s: String) -> Data? {
    var padded = s
    let mod = padded.count % 4
    if mod == 2 { padded += "==" }
    else if mod == 3 { padded += "=" }
    else if mod == 1 { return nil }
    return Data(base64Encoded: padded)
}

func base64EncodeUnpadded(_ d: Data) -> String {
    let s = d.base64EncodedString()
    if let eq = s.firstIndex(of: "=") {
        return String(s[..<eq])
    }
    return s
}

// MARK: - Data scanning helper

private extension Data {
    /// Find the first occurrence of `byte` at or after `offset`.
    func firstIndex(of byte: UInt8, after offset: Int) -> Int? {
        var i = offset
        while i < self.count {
            if self[i] == byte { return i }
            i += 1
        }
        return nil
    }
}
