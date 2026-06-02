// HTTP client for the encounter-relay (packages/encounter-relay/).
//
// All endpoints are documented in packages/encounter-relay/README.md.
// Base URL comes from app.json's `expo.extra.relayBaseUrl`, overridable
// via the EXPO_PUBLIC_RELAY_URL env var at build time. For the demo:
// the operator's Sequoia Mac IP on the local Wi-Fi (e.g. http://192.168.x.x:8080).

import Constants from 'expo-constants';

const fallbackBaseUrl = 'http://192.168.1.42:8080';
const baseUrl = (process.env.EXPO_PUBLIC_RELAY_URL
  ?? Constants.expoConfig?.extra?.relayBaseUrl
  ?? fallbackBaseUrl).replace(/\/$/, '');

export function getRelayBaseUrl() {
  return baseUrl;
}

/**
 * GET /encounter?for=<patientRecipient>
 * Returns the list of EncounterRequests addressed to this patient that
 * have not yet been approved/denied and haven't expired.
 */
export async function fetchPendingRequests(patientRecipient, { signal } = {}) {
  const url = `${baseUrl}/encounter?for=${encodeURIComponent(patientRecipient)}`;
  const res = await fetch(url, { signal });
  if (!res.ok) {
    throw new Error(`relay GET ${url} → ${res.status}`);
  }
  const data = await res.json();
  return data.requests ?? [];
}

/**
 * POST /encounter/<id>/approval
 * Submits the patient's wrapped-keys approval back to the relay,
 * which the clinician will then poll for and decrypt.
 */
export async function submitApproval(approval) {
  const url = `${baseUrl}/encounter/${encodeURIComponent(approval.encounterId)}/approval`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(approval),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`relay POST ${url} → ${res.status}: ${text}`);
  }
  return await res.json();
}

/** Liveness check; useful for diagnostic UI ("relay reachable?"). */
export async function pingRelay() {
  try {
    const res = await fetch(`${baseUrl}/healthz`, { method: 'GET' });
    return res.ok;
  } catch {
    return false;
  }
}
