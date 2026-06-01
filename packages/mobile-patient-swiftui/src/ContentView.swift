// ContentView.swift  (memoryOraclePatient — Phase 3c-iv SwiftUI)
//
// Top-level state machine routing between three screens:
//   home    — QR + pending requests list (default after boot)
//   consent — single-request approve/deny
//   audit   — last-50 audit entries
//
// Boot sequence: check SE availability → get-or-create the patient's
// SE-bound identity → render home.
//
// See: docs/plans/verum-phase-3c-iv-swiftui-pivot-20260601.md

import SwiftUI
import Combine

private let SE_KEY_TAG = "mo.patient.namespace.v1"

@MainActor
final class AppModel: ObservableObject {
    enum Screen {
        case boot
        case home
        case consent(EncounterRequest)
        case audit
    }

    @Published var screen: Screen = .boot
    @Published var recipient: String? = nil
    @Published var bootError: String? = nil
    @Published var seAvailable: Bool = SeAgeService.isAvailable()

    func boot() async {
        guard seAvailable else {
            screen = .boot
            return
        }
        do {
            let r = try SeAgeService.getOrCreateIdentity(tag: SE_KEY_TAG)
            self.recipient = r
            self.screen = .home
        } catch {
            self.bootError = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            switch model.screen {
            case .boot:
                bootView
            case .home:
                if let r = model.recipient {
                    HomeView(patientRecipient: r,
                             onSelectRequest: { req in model.screen = .consent(req) },
                             onOpenAudit:     { model.screen = .audit })
                }
            case .consent(let req):
                ConsentView(request: req,
                            onDismiss: { model.screen = .home })
            case .audit:
                AuditView(onDismiss: { model.screen = .home })
            }
        }
        .task {
            if case .boot = model.screen, model.recipient == nil {
                await model.boot()
            }
        }
    }

    private var bootView: some View {
        VStack(spacing: 20) {
            Text("memory-oracle Patient")
                .font(.title)
                .fontWeight(.bold)
            if !model.seAvailable {
                cardError(title: "Secure Enclave not available",
                          body: "Requires real iPhone hardware (iPhone 5s+). The iOS Simulator does not have a Secure Enclave and cannot run this app.")
            } else if let e = model.bootError {
                cardError(title: "Identity bootstrap failed",
                          body: e)
            } else {
                ProgressView()
                Text("booting…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cardError(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundColor(.red)
            Text(body).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
    }
}

#Preview {
    ContentView()
}
