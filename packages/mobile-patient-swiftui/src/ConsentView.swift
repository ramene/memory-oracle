// ConsentView.swift
//
// Single-encounter approve/deny screen. Shows clinician identity, scope
// chips, and a live TTL countdown. Approve fires the encryption +
// relay-submit flow (no Face ID — encryption only uses public keys).
// Deny logs an audit entry; the encounter expires naturally on the
// relay's TTL sweep.

import SwiftUI
import Combine

struct ConsentView: View {
    let request: EncounterRequest
    var onDismiss: () -> Void

    @State private var busy = false
    @State private var result: ResultState? = nil
    @State private var error: String? = nil
    @State private var secondsLeft: Int = 0

    enum ResultState { case approved, denied }

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let r = result {
            resultView(r)
        } else {
            formView
        }
    }

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: onDismiss) {
                    Text("← back")
                        .font(.callout)
                        .foregroundColor(.blue)
                }
                .disabled(busy)
                .padding(.top, 30)

                Text("Encounter request")
                    .font(.title).fontWeight(.bold)

                identityCard
                scopesCard
                ttlCard
                if let e = error { errorBox(e) }
                if secondsLeft <= 0 {
                    errorBox("This request has expired. Ask the clinician to send a new one.")
                }

                Button(action: handleApprove) {
                    HStack {
                        Spacer()
                        if busy { ProgressView().tint(.white) } else { Text("Approve") }
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .font(.headline)
                    .padding(18)
                    .background((busy || secondsLeft <= 0) ? Color.gray : Color(red: 0.23, green: 0.6, blue: 0.28))
                    .cornerRadius(10)
                }
                .disabled(busy || secondsLeft <= 0)

                Button(action: handleDeny) {
                    Text("Deny")
                        .foregroundColor(.white)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(busy ? Color.gray : Color(red: 0.8, green: 0.27, blue: 0.27))
                        .cornerRadius(10)
                }
                .disabled(busy)

                Text("Approving releases time-limited session keys to \(request.clinicianName) for the scope(s) above. The clinician's device decrypts the keys with their own Face ID / Touch ID. Your private key never leaves this device's Secure Enclave.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(24)
        }
        .onReceive(countdownTimer) { _ in tickCountdown() }
        .onAppear { tickCountdown() }
    }

    private func resultView(_ r: ResultState) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Text(r == .approved ? "Approved ✓" : "Denied")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(r == .approved ? Color(red: 0.23, green: 0.6, blue: 0.28) : Color(red: 0.8, green: 0.27, blue: 0.27))
            Text(r == .approved
                 ? "Wrapped session keys for \(request.requestedScopes.count) scope(s) sent to \(request.clinicianName). Valid for \(request.ttlSeconds / 60) minutes."
                 : "\(request.clinicianName) will not be able to retrieve a session key for this encounter.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: onDismiss) {
                Text("Done")
                    .foregroundColor(.white)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }

    // MARK: - cards

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From").font(.caption).foregroundColor(Color(red: 0.27, green: 0.27, blue: 0.4))
            Text(request.clinicianName).font(.title3).fontWeight(.bold)
            Text(request.clinicianRecipient)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.27, green: 0.27, blue: 0.4))
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.96, green: 0.97, blue: 1.0))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.8, green: 0.85, blue: 0.93), lineWidth: 1))
        .cornerRadius(10)
    }

    private var scopesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requesting access to").font(.caption).foregroundColor(Color(red: 0.13, green: 0.4, blue: 0.27))
            FlowLayout(spacing: 6) {
                ForEach(request.requestedScopes, id: \.self) { s in
                    Text(s)
                        .font(.callout)
                        .foregroundColor(Color(red: 0.2, green: 0.4, blue: 0.2))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 0.72, green: 0.85, blue: 0.66), lineWidth: 1))
                        .cornerRadius(14)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 1.0, blue: 0.96))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.8, green: 0.91, blue: 0.75), lineWidth: 1))
        .cornerRadius(10)
    }

    private var ttlCard: some View {
        VStack(spacing: 4) {
            Text("Encounter valid for").font(.caption).foregroundColor(.secondary)
            Text(secondsLeft <= 0 ? "expired" : formatTtl(secondsLeft))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(secondsLeft <= 0 ? Color(red: 0.8, green: 0.27, blue: 0.27) : Color(red: 0.13, green: 0.13, blue: 0.27))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundColor(Color(red: 0.45, green: 0.13, blue: 0.13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.99, green: 0.92, blue: 0.92))
            .cornerRadius(8)
    }

    // MARK: - logic

    private func tickCountdown() {
        let issuedDate = ISO8601DateFormatter().date(from: request.issuedAt) ?? Date()
        let expiresDate = issuedDate.addingTimeInterval(TimeInterval(request.ttlSeconds))
        secondsLeft = max(0, Int(expiresDate.timeIntervalSinceNow))
    }

    private func handleApprove() {
        busy = true
        error = nil
        Task {
            do {
                _ = try await ApproveHandler.approve(request)
                result = .approved
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func handleDeny() {
        busy = true
        error = nil
        ApproveHandler.deny(request)
        result = .denied
        busy = false
    }

    private func formatTtl(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%dm %02ds", m, s)
    }
}

// Minimal flow layout for scope chips (SwiftUI's Layout protocol, iOS 16+).
// Falls back to a wrapping HStack via lazy approach so iOS 14 builds too.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxRowW: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                maxRowW = max(maxRowW, x - spacing)
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        maxRowW = max(maxRowW, x - spacing)
        return CGSize(width: max(0, maxRowW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
