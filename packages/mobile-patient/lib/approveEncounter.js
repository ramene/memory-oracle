// Approve-encounter handler: invoked from ConsentScreen after the user
// taps "Approve". For each requested scope, generates a fresh 16-byte
// session key, wraps it via SeAge.encryptToRecipient() (3c-ii) to the
// clinician's age recipient, base64-encodes the result, and POSTs an
// EncounterApproval back to the relay.
//
// Each call to SeAge.encryptToRecipient does NOT fire Face ID — encryption
// only needs the clinician's public key. The Face ID gate is whatever
// happens between the consent screen's tap and this function being called
// (the consent UI itself enforces the precondition; SE-bound private-key
// operations don't happen on the encrypt side).
//
// Note: this means a malicious patient app could send wrappedKeys without
// a user-visible Face ID prompt. The threat model assumes the patient's
// device is operator-trusted; Face ID gates the *initial* key generation
// AND any decrypt of returned records. For paper purposes that's sufficient.

import * as Crypto from 'expo-crypto';
import SeAge from 'se-age';
import { submitApproval } from './relay.js';
import { appendAudit } from './audit.js';

/**
 * @param request EncounterRequest from the relay
 * @returns the EncounterApproval that was successfully submitted
 */
export async function approveEncounter(request) {
  const { encounterId, clinicianRecipient, clinicianName, requestedScopes, ttlSeconds } = request;
  const wrappedKeys = {};
  for (const scope of requestedScopes) {
    const sessionKey = await Crypto.getRandomBytesAsync(16);
    const encryptedBytes = await SeAge.encryptToRecipient(sessionKey, clinicianRecipient);
    wrappedKeys[scope] = bytesToBase64(encryptedBytes);
  }

  const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
  const approval = {
    '@type': 'EncounterApproval',
    encounterId,
    wrappedKeys,
    expiresAt,
  };

  await submitApproval(approval);

  await appendAudit({
    event: 'encounter_approved',
    encounterId,
    clinicianName,
    clinicianRecipient_prefix: clinicianRecipient.slice(0, 18),
    scopes: requestedScopes,
    expiresAt,
  });

  return approval;
}

export async function denyEncounter(request) {
  await appendAudit({
    event: 'encounter_denied',
    encounterId: request.encounterId,
    clinicianName: request.clinicianName,
    scopes: request.requestedScopes,
  });
  // No relay POST for denial in 3c-iv — clinician's GET on the approval
  // endpoint will keep returning 404 until the encounter expires. A
  // future revision could add an explicit /deny endpoint for faster
  // clinician-side UX.
}

// ── Base64 encode a Uint8Array (RN doesn't have btoa for bytes). ──
function bytesToBase64(bytes) {
  // React Native has globalThis.btoa for strings, but for bytes we want
  // a byte-correct encoder. Use a small inline implementation rather
  // than pulling in a base64 dep.
  const ALPH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += ALPH[(n >> 18) & 63] + ALPH[(n >> 12) & 63] + ALPH[(n >> 6) & 63] + ALPH[n & 63];
  }
  if (i < bytes.length) {
    const remain = bytes.length - i;
    let n = bytes[i] << 16;
    if (remain === 2) n |= bytes[i + 1] << 8;
    out += ALPH[(n >> 18) & 63] + ALPH[(n >> 12) & 63];
    out += remain === 2 ? ALPH[(n >> 6) & 63] + '=' : '==';
  }
  return out;
}
