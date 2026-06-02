// HomeView.swift
//
// Default screen: QR encoding patient's identity + relay URL, plus a
// live list of pending encounter requests. Tap a request → ConsentView.

import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins

struct HomeView: View {
    let patientRecipient: String
    var onSelectRequest: (EncounterRequest) -> Void
    var onOpenAudit: () -> Void

    @StateObject private var poller: PendingRequestsPoller

    init(patientRecipient: String,
         onSelectRequest: @escaping (EncounterRequest) -> Void,
         onOpenAudit: @escaping () -> Void) {
        self.patientRecipient = patientRecipient
        self.onSelectRequest = onSelectRequest
        self.onOpenAudit = onOpenAudit
        self._poller = StateObject(
            wrappedValue: PendingRequestsPoller(patientRecipient: patientRecipient)
        )
    }

    private var relayBaseUrl: String { RelayConfig.baseUrl }

    private var qrPayload: String {
        // JSON the clinician's scanner expects. Compact, single-line.
        let dict: [String: Any] = [
            "v": 1,
            "recipient": patientRecipient,
            "relay": relayBaseUrl,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return patientRecipient
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                qrCard
                pendingHeader
                if let e = poller.errorMessage { errorBox(e) }
                if poller.requests.isEmpty && poller.errorMessage == nil {
                    emptyBox
                }
                ForEach(poller.requests) { req in
                    Button { onSelectRequest(req) } label: { requestCard(req) }
                        .buttonStyle(.plain)
                }
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
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
    }

    // MARK: - subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("memory-oracle Patient").font(.title).fontWeight(.bold)
            Text("Phase 3c-iv · SwiftUI native").font(.caption).foregroundColor(.secondary)
        }
        .padding(.top, 30)
    }

    private var qrCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your patient QR")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(Color(red: 0.27, green: 0.27, blue: 0.4))
            HStack { Spacer(); qrImage; Spacer() }
            Text("Clinician scans this to request an encounter.")
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
            Text(patientRecipient)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.13, green: 0.13, blue: 0.27))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("relay: \(relayBaseUrl) \(relayBadge)")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(red: 0.96, green: 0.97, blue: 1.0))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.8, green: 0.85, blue: 0.93), lineWidth: 1))
        .cornerRadius(10)
    }

    private var qrImage: some View {
        Group {
            if let cgImage = makeQR(payload: qrPayload) {
                Image(decorative: cgImage, scale: 1.0)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                Text("(QR render failed)")
                    .font(.caption)
                    .frame(width: 220, height: 220)
            }
        }
    }

    private var relayBadge: String {
        switch poller.relayReachable {
        case .some(true):  return "✓ reachable"
        case .some(false): return "⚠ unreachable"
        case .none:        return "…"
        }
    }

    private var pendingHeader: some View {
        HStack {
            Text("Pending requests (\(poller.requests.count))")
                .font(.headline)
            Spacer()
            Button(action: { Task { await poller.fetchOnce() } }) {
                Text(poller.loading ? "…" : "refresh")
                    .font(.callout)
                    .foregroundColor(.blue)
            }
            .disabled(poller.loading)
        }
    }

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("relay error: \(message)")
                .font(.footnote).foregroundColor(Color(red: 0.45, green: 0.13, blue: 0.13))
            Text("auto-retrying every 5s while app is foregrounded")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(red: 0.99, green: 0.92, blue: 0.92))
        .cornerRadius(8)
    }

    private var emptyBox: some View {
        Text("No pending encounter requests. When a clinician scans your QR, a request appears here for your approval.")
            .font(.footnote)
            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.47))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.96, green: 0.97, blue: 0.97))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.87, green: 0.88, blue: 0.9), lineWidth: 1))
            .cornerRadius(10)
    }

    private func requestCard(_ req: EncounterRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(req.clinicianName)
                .font(.headline)
                .foregroundColor(Color(red: 0.33, green: 0.27, blue: 0.13))
            Text("Requesting: \(req.requestedScopes.joined(separator: ", "))")
                .font(.subheadline)
                .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.27))
            Text("Valid for \(req.ttlSeconds / 60) min · tap to review")
                .font(.caption)
                .foregroundColor(Color(red: 0.53, green: 0.53, blue: 0.4))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1.0, green: 0.98, blue: 0.94))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.91, green: 0.78, blue: 0.56), lineWidth: 1))
        .cornerRadius(10)
    }

    // MARK: - QR rendering (CoreImage, no third-party dep)

    private func makeQR(payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
