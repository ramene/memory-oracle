// ContentView.swift  (memoryOracleClinician — Phase 3c-v SwiftUI)
//
// State machine routes:
//   boot      → check SE + generate/load identity
//   home      → "Scan patient QR" + own identity
//   scanning  → camera scanner
//   request   → scope picker + TTL (after QR scan)
//   active    → poll for approval → decrypt → render records
//   audit     → local audit log viewer

import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case boot
        case firstSetup                 // no identities exist yet
        case home
        case scanning
        case request(PatientQRPayload)
        case active(encounterId: String, request: EncounterRequest, baseUrl: String, patientId: String)
        case audit
    }

    @Published var screen: Screen = .boot
    @Published var activeIdentity: ClinicianIdentity? = nil
    @Published var bootError: String? = nil
    @Published var seAvailable: Bool = SeAgeService.isAvailable()

    func boot() async {
        guard seAvailable else { return }
        let identities = IdentityStore.all()
        if identities.isEmpty {
            screen = .firstSetup
            return
        }
        // Load active identity; if none set, default to first
        if let active = IdentityStore.active() {
            activeIdentity = active
        } else if let first = identities.first {
            try? IdentityStore.setActive(first.id)
            activeIdentity = first
        }
        screen = .home
    }

    func onIdentityChange() {
        activeIdentity = IdentityStore.active()
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            switch model.screen {
            case .boot:
                bootView
            case .firstSetup:
                FirstIdentitySetup(onCreated: {
                    Task { await model.boot() }
                })
            case .home:
                if let identity = model.activeIdentity {
                    HomeView(
                        clinicianRecipient: identity.recipient,
                        clinicianName: identity.name,
                        onStartScan: { model.screen = .scanning },
                        onOpenAudit: { model.screen = .audit },
                        onIdentityChange: {
                            model.onIdentityChange()
                        }
                    )
                }
            case .scanning:
                scanningWrapper
            case .request(let payload):
                if let identity = model.activeIdentity {
                    EncounterRequestView(
                        patient: payload,
                        clinicianRecipient: identity.recipient,
                        clinicianName: identity.name,
                        onSubmitted: { id, req, client in
                            // For demo: patientId is hardcoded for the synthetic corpus.
                            // Real system would derive patientId from the QR payload or
                            // from the relay's encounter record.
                            model.screen = .active(
                                encounterId: id,
                                request: req,
                                baseUrl: client.baseUrl,
                                patientId: "jane-doe-1959"
                            )
                        },
                        onCancel: { model.screen = .home }
                    )
                }
            case .active(let encounterId, let request, let baseUrl, let patientId):
                if let identity = model.activeIdentity {
                    ActiveEncounterView(
                        encounterId: encounterId,
                        request: request,
                        client: RelayClient(baseUrl: baseUrl),
                        clinicianKeyTag: identity.seKeyTag,
                        clinicianName: identity.name,
                        patientId: patientId,
                        relayBaseUrl: baseUrl,
                        onEnd: { model.screen = .home }
                    )
                }
            case .audit:
                AuditView(onDismiss: { model.screen = .home })
            }
        }
        .task {
            if case .boot = model.screen, model.activeIdentity == nil {
                await model.boot()
            }
        }
    }

    private var bootView: some View {
        VStack(spacing: 20) {
            Text("memory-oracle Dr.").font(.title).fontWeight(.bold)
            if !model.seAvailable {
                cardError(title: "Secure Enclave not available",
                          body: "Requires real iPad / iPhone hardware. The iOS Simulator does not have a Secure Enclave and cannot run this app.")
            } else if let e = model.bootError {
                cardError(title: "Identity bootstrap failed", body: e)
            } else {
                ProgressView()
                Text("booting…").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scanningWrapper: some View {
        ZStack(alignment: .topLeading) {
            ScannerView(
                onCodeScanned: { code in handleScanned(code) },
                onError: { msg in
                    // surfacing camera errors back to home
                    model.bootError = msg
                    model.screen = .home
                }
            )
            .edgesIgnoringSafeArea(.all)
            Button(action: { model.screen = .home }) {
                Text("← cancel")
                    .font(.callout)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }
            .padding(.top, 60)
            .padding(.leading, 16)
        }
    }

    private func handleScanned(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PatientQRPayload.self, from: data),
              payload.v == 1 else {
            // Not a recognized payload — flash error and bounce home
            model.bootError = "QR did not contain a valid patient payload"
            model.screen = .home
            return
        }
        model.screen = .request(payload)
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
