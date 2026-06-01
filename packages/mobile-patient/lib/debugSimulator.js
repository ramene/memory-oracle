// Reviewer / debug mode: simulate an incoming clinician EncounterRequest
// without needing a real clinician device. Useful for:
//
//   1. App Store Review — reviewers don't have an iPad clinician app;
//      this lets them verify the consent flow works on the patient app
//      alone. Include in App Review notes: "Tap 'Simulate clinician
//      request' to test the consent flow."
//
//   2. Local development on Mac/Sequoia when only one iPhone is around.
//
// How it works: posts an EncounterRequest to the relay using our own
// patient recipient as the routing key. The poller in usePendingRequests
// then picks it up on the next tick. The clinician identity is a
// hardcoded fake recipient — it's a real bech32-encoded P-256 pubkey
// (so encryptToRecipient won't reject it), but the corresponding
// private key is unknown / nonexistent. The wrappedKeys we send back
// to the relay can never be decrypted by anyone; that's fine for
// validating the UI flow.

import { getRelayBaseUrl } from './relay.js';

// Three plausible-looking fake clinicians. Their recipients are real,
// valid bech32-encoded P-256 pubkeys (produced via macOS age-plugin-se;
// matched Phase 2 + 3b-i validation runs). The private keys exist on
// other devices' Secure Enclaves and are not relevant — these are
// public-key-only encryption targets.
//
// To add another: run on Sequoia:
//   age-plugin-se keygen --access-control any-biometry-or-passcode -o /tmp/fake.txt
//   grep '^# public key:' /tmp/fake.txt | sed 's/^# public key: //'
const FAKE_CLINICIANS = [
  {
    name: 'Dr. Y. Chen (DEMO)',
    recipient: 'age1se1qwg6zhcp8strap5recwypq5r8kvrzy5jzdrg6383mfv32yzfme5pwxf2a4e',
  },
  {
    name: 'Dr. R. Patel (DEMO)',
    recipient: 'age1se1qgq83eu3sw8s46dnqey8p99kmelwpt88th92jfnutj3pu570pdz9ucnmn0n',
  },
];

const SCOPE_PRESETS = [
  ['allergies', 'meds'],
  ['allergies'],
  ['meds', 'recent-labs'],
  ['allergies', 'meds', 'past-procedures'],
];

/**
 * POSTs a simulated EncounterRequest to the relay. Returns the
 * encounterId on success.
 */
export async function simulateClinicianRequest(patientRecipient, options = {}) {
  const clinician = options.clinician
    ?? FAKE_CLINICIANS[Math.floor(Math.random() * FAKE_CLINICIANS.length)];
  const scopes = options.scopes
    ?? SCOPE_PRESETS[Math.floor(Math.random() * SCOPE_PRESETS.length)];
  const ttlSeconds = options.ttlSeconds ?? 900;

  const baseUrl = getRelayBaseUrl();
  const body = {
    '@type': 'EncounterRequest',
    clinicianRecipient: clinician.recipient,
    clinicianName: clinician.name,
    patientRecipient,
    requestedScopes: scopes,
    ttlSeconds,
    issuedAt: new Date().toISOString(),
  };

  const res = await fetch(`${baseUrl}/encounter`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`relay POST /encounter → ${res.status}: ${text}`);
  }
  const data = await res.json();
  return data.encounterId;
}
