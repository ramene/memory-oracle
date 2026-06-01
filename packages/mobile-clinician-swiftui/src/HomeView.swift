// HomeView.swift  (clinician home)
//
// Shows clinician's own SE-bound identity (informational — patient never
// sees this; the clinician's recipient travels in the EncounterRequest
// body), the "Start encounter" button (→ scanner), an audit-log link.

import SwiftUI
import Combine

struct HomeView: View {
    let clinicianRecipient: String
    let clinicianName: String
    var onStartScan: () -> Void
    var onOpenAudit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                identityCard
                Button(action: onStartScan) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                        Text("Scan patient QR")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(red: 0.07, green: 0.4, blue: 0.65))
                    .cornerRadius(12)
                }
                Text("Tap to begin an encrypted, time-limited encounter. The patient's iPhone must be on the same Wi-Fi network as this device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenAudit) {
                    Text("View audit log →")
                        .font(.callout)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("memory-oracle Dr.")
                .font(.title).fontWeight(.bold)
            Text("Phase 3c-v · SwiftUI native")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 30)
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clinician identity")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(Color(red: 0.27, green: 0.27, blue: 0.4))
            Text(clinicianName)
                .font(.title3).fontWeight(.bold)
            Text("Your SE-bound recipient (this device's Secure Enclave):")
                .font(.caption2).foregroundColor(.secondary)
            Text(clinicianRecipient)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.13, green: 0.13, blue: 0.27))
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.96, green: 0.97, blue: 1.0))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.8, green: 0.85, blue: 0.93), lineWidth: 1))
        .cornerRadius(10)
    }
}
