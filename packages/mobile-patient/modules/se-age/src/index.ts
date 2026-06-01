import { requireNativeModule } from 'expo-modules-core';

export interface SeAgeNative {
  /**
   * True iff this device has a real Secure Enclave (iPhone 5s+ / iPad Air+).
   * Simulator: false. Older devices: false.
   */
  isAvailable(): boolean;

  /**
   * Returns the existing age recipient for `tag`, or generates a new
   * Secure Enclave-bound P-256 keypair (no Face ID prompt — keygen is
   * non-interactive) and returns the new recipient.
   *
   * Recipient format: `age1se1...` (bech32, HRP="age1se", 33-byte
   * compressed P-256 pubkey). Wire-compatible with the macOS
   * `age-plugin-se` binary.
   */
  getOrCreateIdentity(tag: string): Promise<string>;

  /**
   * Returns the recipient for `tag` if a key already exists, else null.
   * Does NOT generate; use `getOrCreateIdentity` to generate.
   */
  getRecipient(tag: string): Promise<string | null>;

  /**
   * ECDH between this device's SE-bound private key (under `tag`) and
   * `peerRecipient`. FIRES Face ID / passcode prompt with `reason`
   * shown to the user. Returns the raw 32-byte shared secret.
   *
   * In Phase 3c this shared secret is fed into HKDF-SHA256 → produces
   * the wrapping key for the file-key blob in the age stanza.
   *
   * Throws `userCancelled` if the user cancels Face ID.
   */
  performKeyAgreement(
    tag: string,
    peerRecipient: string,
    reason: string,
  ): Promise<Uint8Array>;

  /**
   * Decrypts an age file (`age-encryption.org/v1` format) addressed to
   * this device's SE-bound identity. Fires Face ID once per matching
   * `piv-p256` stanza (typically once — patient records have a single
   * recipient).
   *
   * Returns the recovered plaintext. Throws:
   *   - `SeAgeUserCancelled` if Face ID is dismissed
   *   - `SeAgeInvalidRecipient` if no piv-p256 stanza matches this identity
   *   - `SeAgeKeyAgreement` for any other decryption failure
   *
   * 3c-i ships single-chunk decryption (≤64KB plaintext). Multi-chunk
   * lands when patient records grow.
   */
  decryptAgeFile(
    tag: string,
    ageBytes: Uint8Array,
    reason: string,
  ): Promise<Uint8Array>;

  /**
   * Deletes the key associated with `tag` (both the Secure Enclave
   * reference and the keychain-persisted dataRepresentation token).
   * Use during patient logout / account reset.
   */
  deleteIdentity(tag: string): Promise<boolean>;
}

const SeAge = requireNativeModule<SeAgeNative>('SeAge');

export default SeAge;
