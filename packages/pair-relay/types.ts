// Wire format for the verum device-pairing handshake (task #165 follow-on).
// Mirrors architecture-notes/docs/architecture/verum-pairing-protocol-2026-06-26.md
// and the iOS Codable structs in verum-ios PairingPayload.swift.
//
// snake_case is LITERAL (the iOS coders use JSONEncoder.verum() with NO key
// conversion + explicit snake_case CodingKeys). The relay never re-serializes
// these for signing — it only routes them — so field order is irrelevant here;
// only the field NAMES must match the wire contract exactly.
//
// All recipients are age1se1... bech32-encoded compressed P-256 pubkeys
// (age-plugin-se on macOS / the local se-age module on iOS).

/** Phone → desktop, POSTed to /pair/claim (echoes the offer's nonce). */
export interface PairingDeviceClaim {
  v: number;                    // 1
  kind: 'verum-pair-claim';
  /** Echoes PairingOffer.nonce — the rendezvous key for this pairing. */
  nonce: string;
  /** Phone's SE-bound recipient — desktop wraps the sub-key TO this. */
  device_recipient: string;     // age1se1...
  /** Human-readable label for the desktop's SAS-confirm + paired-device list. */
  device_label: string;
  /** ISO-8601 timestamp the phone issued the claim. */
  issued_at: string;
}

/** Desktop → relay, POSTed to /pair once the sub-key is wrapped. */
export interface AgeFileDelivery {
  /** Rendezvous key — must match an existing claim's nonce. */
  nonce: string;
  /** Must equal the claim's device_recipient (anti-cross-retrieval). */
  for: string;                  // age1se1...
  /** base64 of the age file (sub-key encrypted to device_recipient). */
  age_file_b64: string;
}

/** Internal: stored relay-side per pairing, keyed by nonce. Ephemeral. */
export interface PairRecord {
  nonce: string;
  /** Set by POST /pair/claim (phone). Null until the phone claims. */
  claim: PairingDeviceClaim | null;
  /** Set by POST /pair (desktop). Null until the desktop delivers. */
  ageFileB64: string | null;
  createdAt: number;            // ms epoch
  expiresAt: number;            // ms epoch — createdAt + ttlSeconds*1000
}
