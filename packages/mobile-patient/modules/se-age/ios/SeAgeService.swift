import Foundation
import CryptoKit
import LocalAuthentication
import Security

enum SeAgeError: LocalizedError {
  case secureEnclaveUnavailable
  case keychainFailure(OSStatus)
  case invalidRecipient(String)
  case userCancelled
  case keyAgreementFailed(String)

  var code: String {
    switch self {
    case .secureEnclaveUnavailable: return "SeAgeUnavailable"
    case .keychainFailure: return "SeAgeKeychain"
    case .invalidRecipient: return "SeAgeInvalidRecipient"
    case .userCancelled: return "SeAgeUserCancelled"
    case .keyAgreementFailed: return "SeAgeKeyAgreement"
    }
  }

  var errorDescription: String? {
    switch self {
    case .secureEnclaveUnavailable:
      return "Secure Enclave is not available on this device (need iPhone 5s+ on real hardware, not Simulator)."
    case .keychainFailure(let status):
      return "Keychain operation failed (OSStatus=\(status))."
    case .invalidRecipient(let detail):
      return "Invalid age recipient: \(detail)"
    case .userCancelled:
      return "User cancelled Face ID."
    case .keyAgreementFailed(let detail):
      return "Key agreement failed: \(detail)"
    }
  }
}

enum SeAgeService {
  private static let keychainService = "ai.memoryoracle.patient.se-age"

  static func isAvailable() -> Bool {
    SecureEnclave.isAvailable
  }

  static func getOrCreateIdentity(tag: String) throws -> String {
    if let existing = try getRecipient(tag: tag) {
      return existing
    }
    guard SecureEnclave.isAvailable else {
      throw SeAgeError.secureEnclaveUnavailable
    }
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
      [.privateKeyUsage, .userPresence],
      &accessError
    ) else {
      throw SeAgeError.keyAgreementFailed(
        "SecAccessControlCreateWithFlags failed: \(accessError?.takeRetainedValue().localizedDescription ?? "unknown")")
    }
    let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    try saveToken(privateKey.dataRepresentation, tag: tag)
    return encodeAgeSeRecipient(publicKey: privateKey.publicKey)
  }

  static func getRecipient(tag: String) throws -> String? {
    guard let token = try loadToken(tag: tag) else { return nil }
    let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: token)
    return encodeAgeSeRecipient(publicKey: privateKey.publicKey)
  }

  static func performKeyAgreement(tag: String, peerRecipient: String, reason: String) throws -> Data {
    guard let token = try loadToken(tag: tag) else {
      throw SeAgeError.keychainFailure(errSecItemNotFound)
    }
    let context = LAContext()
    context.localizedReason = reason
    let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
      dataRepresentation: token,
      authenticationContext: context
    )
    let peerCompressed = try decodeAgeSeRecipient(peerRecipient)
    let peerKey: P256.KeyAgreement.PublicKey
    do {
      peerKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: peerCompressed)
    } catch {
      throw SeAgeError.invalidRecipient("compressed point did not decode to a valid P-256 public key")
    }
    do {
      let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
      return shared.withUnsafeBytes { Data($0) }
    } catch let e as NSError where e.code == errSecUserCanceled || e.code == LAError.userCancel.rawValue {
      throw SeAgeError.userCancelled
    } catch {
      throw SeAgeError.keyAgreementFailed(error.localizedDescription)
    }
  }

  static func deleteIdentity(tag: String) throws -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: tag,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess { return true }
    if status == errSecItemNotFound { return false }
    throw SeAgeError.keychainFailure(status)
  }

  // MARK: - Keychain persistence of the SE dataRepresentation token.
  // The token is an opaque reference (~140 bytes) — not the private key
  // itself — that the Secure Enclave uses to look up the key on demand.
  // Stored as a generic-password keychain item, non-syncable.

  private static func saveToken(_ token: Data, tag: String) throws {
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: tag,
    ]
    SecItemDelete(baseQuery as CFDictionary)
    var add = baseQuery
    add[kSecValueData as String] = token
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw SeAgeError.keychainFailure(status)
    }
  }

  private static func loadToken(tag: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: tag,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw SeAgeError.keychainFailure(status)
    }
    return result as? Data
  }
}
