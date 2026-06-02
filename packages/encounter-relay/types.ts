// Wire format for the encounter handshake. JSON-LD-style "@type" fields
// for paper-figure friendliness. All recipients are age1se1... bech32-
// encoded compressed P-256 pubkeys (produced by Verum --se on macOS or
// the local se-age module on iOS).
//
// These types are duplicated in the mobile apps (patient + clinician) —
// keep them in sync. If they grow significantly, promote to a shared
// package.

export interface EncounterRequest {
  '@type': 'EncounterRequest';
  /** Server-assigned UUIDv4 (relay generates on POST). */
  encounterId: string;
  /** Clinician's age1se1... — patient encrypts wrapped keys TO this. */
  clinicianRecipient: string;
  /** Human-readable name for the consent UI. */
  clinicianName: string;
  /** Patient's age1se1... — relay routes the request to this patient. */
  patientRecipient: string;
  /** Which scopes the clinician is asking to access (e.g. ["allergies", "meds"]). */
  requestedScopes: string[];
  /** Encounter validity window in seconds (default: 900 = 15 min). */
  ttlSeconds: number;
  /** ISO-8601 timestamp the clinician issued the request. */
  issuedAt: string;
}

export interface EncounterApproval {
  '@type': 'EncounterApproval';
  /** Must match the request's encounterId. */
  encounterId: string;
  /** Per-scope wrapped session keys: scope name → base64 of age-encrypted blob. */
  wrappedKeys: Record<string, string>;
  /** ISO-8601 — when the wrapped keys stop being valid (issuedAt + ttlSeconds). */
  expiresAt: string;
  /** Optional reference to a memory-oracle audit log entry for the HIPAA §164.526 trail. */
  auditEntryId?: string;
}

/** Internal: stored relay-side per encounter. */
export interface EncounterRecord {
  request: EncounterRequest;
  approval: EncounterApproval | null;
  createdAt: number;       // ms epoch
  expiresAt: number;       // ms epoch — createdAt + ttlSeconds*1000
}
