import Foundation

// Bech32 (BIP-173) encode/decode. NOT bech32m — age uses bech32 per the
// age specification (https://age-encryption.org/v1).
//
// Reference: https://github.com/sipa/bech32

enum Bech32Error: LocalizedError {
  case invalidCharacter(Character)
  case invalidChecksum
  case invalidSeparator
  case mixedCase
  case stringTooShort
  case stringTooLong
  case invalidHrp
  case invalidData

  var errorDescription: String? {
    switch self {
    case .invalidCharacter(let c): return "Invalid bech32 character: '\(c)'"
    case .invalidChecksum:         return "Bech32 checksum mismatch"
    case .invalidSeparator:        return "Bech32 separator '1' missing or misplaced"
    case .mixedCase:               return "Bech32 string mixes upper and lower case"
    case .stringTooShort:          return "Bech32 string too short"
    case .stringTooLong:           return "Bech32 string too long"
    case .invalidHrp:              return "Invalid bech32 human-readable part"
    case .invalidData:             return "Invalid bech32 data segment"
    }
  }
}

enum Bech32 {
  private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

  static func encode(hrp: String, data: Data) -> String {
    let converted = convertBits(data: [UInt8](data), fromBits: 8, toBits: 5, pad: true)
    let checksum = createChecksum(hrp: hrp, data: converted)
    let combined = converted + checksum
    var s = hrp + "1"
    for v in combined {
      s.append(charset[Int(v)])
    }
    return s
  }

  static func decode(_ s: String) throws -> (hrp: String, data: Data) {
    if s.count < 8 { throw Bech32Error.stringTooShort }
    if s.count > 1023 { throw Bech32Error.stringTooLong }

    let hasLower = s.contains { $0.isLowercase }
    let hasUpper = s.contains { $0.isUppercase }
    if hasLower && hasUpper { throw Bech32Error.mixedCase }
    let lower = s.lowercased()

    guard let sepRange = lower.range(of: "1", options: .backwards) else {
      throw Bech32Error.invalidSeparator
    }
    let sepIndex = lower.distance(from: lower.startIndex, to: sepRange.lowerBound)
    if sepIndex < 1 || sepIndex + 7 > lower.count {
      throw Bech32Error.invalidSeparator
    }

    let hrp = String(lower[..<sepRange.lowerBound])
    for c in hrp {
      let v = c.asciiValue ?? 0
      if v < 33 || v > 126 { throw Bech32Error.invalidHrp }
    }

    var values: [UInt8] = []
    for c in lower[sepRange.upperBound...] {
      guard let idx = charset.firstIndex(of: c) else {
        throw Bech32Error.invalidCharacter(c)
      }
      values.append(UInt8(idx))
    }

    if !verifyChecksum(hrp: hrp, data: values) {
      throw Bech32Error.invalidChecksum
    }

    let dataValues = Array(values.dropLast(6))
    let bytes = convertBits(data: dataValues, fromBits: 5, toBits: 8, pad: false)
    return (hrp: hrp, data: Data(bytes))
  }

  // MARK: - Polymod / checksum

  private static func polymod(_ values: [UInt8]) -> UInt32 {
    let gen: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
    var chk: UInt32 = 1
    for v in values {
      let b = chk >> 25
      chk = ((chk & 0x1ff_ffff) << 5) ^ UInt32(v)
      for i in 0..<5 {
        if ((b >> i) & 1) != 0 {
          chk ^= gen[i]
        }
      }
    }
    return chk
  }

  private static func hrpExpand(_ hrp: String) -> [UInt8] {
    var ret: [UInt8] = []
    for c in hrp { ret.append((c.asciiValue ?? 0) >> 5) }
    ret.append(0)
    for c in hrp { ret.append((c.asciiValue ?? 0) & 31) }
    return ret
  }

  private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
    polymod(hrpExpand(hrp) + data) == 1
  }

  private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
    let values = hrpExpand(hrp) + data + [UInt8](repeating: 0, count: 6)
    let mod = polymod(values) ^ 1
    var ret: [UInt8] = []
    for i in 0..<6 {
      ret.append(UInt8((mod >> (5 * (5 - i))) & 31))
    }
    return ret
  }

  // MARK: - Bit width conversion

  static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8] {
    var acc: Int = 0
    var bits: Int = 0
    var ret: [UInt8] = []
    let maxv: Int = (1 << toBits) - 1
    for value in data {
      acc = (acc << fromBits) | Int(value)
      bits += fromBits
      while bits >= toBits {
        bits -= toBits
        ret.append(UInt8((acc >> bits) & maxv))
      }
    }
    if pad {
      if bits > 0 {
        ret.append(UInt8((acc << (toBits - bits)) & maxv))
      }
    }
    return ret
  }
}
