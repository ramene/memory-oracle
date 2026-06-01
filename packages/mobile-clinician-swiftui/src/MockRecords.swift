// MockRecords.swift
//
// Hardcoded synthetic patient records per scope. In a real system, the
// clinician's device would fetch the encrypted record from a memory-oracle
// backend and decrypt with the session key the patient just released.
// For the LNCS §7.4 demo, the SESSION KEY recovery (which fires Face ID
// on the clinician's device) is the cryptographic event; the actual
// record content is illustrative.
//
// All records are synthetic. The warfarin → apixaban anticoagulant
// reversal pattern matches the clinical-amendment proof used as the
// running example in the paper.

import Foundation

enum MockRecords {
    static let records: [String: String] = [
        "allergies": """
        ⚠ Penicillin (anaphylaxis, 2014)
        Shellfish (urticaria)
        """,

        "meds": """
        Apixaban 5mg BID  ⬅ active anticoagulant
          (switched from warfarin 2026-01-14;
           reversal agent: andexanet alfa, NOT FFP)
        Metformin 500mg BID
        Lisinopril 10mg daily
        """,

        "recent-labs": """
        HbA1c    6.8%   (2026-05-12)
        TSH      2.1    (2026-04-20)
        Anti-Xa  0.45   (2026-05-01, apixaban therapeutic)
        """,

        "past-procedures": """
        Appendectomy (2018)
        Right knee arthroscopy (2022)
        """,
    ]

    static func render(scope: String) -> String {
        records[scope] ?? "(no record on file for scope: \(scope))"
    }
}
