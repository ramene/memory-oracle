// DebugSimulator.swift
//
// Reviewer / demo mode: simulate an incoming clinician EncounterRequest
// without needing a real clinician device. Useful for:
//
//   1. App Store Review — reviewers don't have an iPad clinician app.
//      This lets them verify the consent flow on the patient app alone.
//
//   2. Local demo flow when only one iPhone is around.
//
// Posts an EncounterRequest to the relay using our own patient recipient
// as the routing key. The poller picks it up on the next tick.
//
// Fake clinicians: real valid bech32-encoded P-256 pubkeys (matched
// Phase 2 + 3b-i validation runs). Corresponding private keys exist
// on other devices' Secure Enclaves and are not relevant — these are
// public-key-only encryption targets. The wrapped keys submitted back
// can never be decrypted, but the UI flow validates in full.

import Foundation

struct FakeClinician {
    let name: String
    let recipient: String
}

enum DebugSimulator {

    static let fakeClinicians: [FakeClinician] = [
        FakeClinician(
            name: "Dr. Y. Chen (DEMO)",
            recipient: "age1se1qwg6zhcp8strap5recwypq5r8kvrzy5jzdrg6383mfv32yzfme5pwxf2a4e"
        ),
        FakeClinician(
            name: "Dr. R. Patel (DEMO)",
            recipient: "age1se1qgq83eu3sw8s46dnqey8p99kmelwpt88th92jfnutj3pu570pdz9ucnmn0n"
        ),
    ]

    static let scopePresets: [[String]] = [
        ["allergies", "meds"],
        ["allergies"],
        ["meds", "recent-labs"],
        ["allergies", "meds", "past-procedures"],
    ]

    /// POSTs a simulated EncounterRequest to the relay. Returns the
    /// server-assigned encounter ID.
    static func simulate(patientRecipient: String,
                        client: RelayClient = RelayClient()) async throws -> String {
        let clinician = fakeClinicians.randomElement()!
        let scopes = scopePresets.randomElement()!
        let ttl = 900

        // The relay assigns encounterId — we just send a placeholder; server
        // overwrites. Building locally with a placeholder UUID is fine because
        // the server's POST handler discards client-side encounterId.
        let req = EncounterRequest(
            type: "EncounterRequest",
            encounterId: UUID().uuidString,   // placeholder, server replaces
            clinicianRecipient: clinician.recipient,
            clinicianName: clinician.name,
            patientRecipient: patientRecipient,
            requestedScopes: scopes,
            ttlSeconds: ttl,
            issuedAt: ISO8601DateFormatter().string(from: Date())
        )

        let response = try await client.submitEncounterRequest(req)
        return response.encounterId
    }
}
