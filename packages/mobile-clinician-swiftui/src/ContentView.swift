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

private let SE_KEY_TAG = "mo.clinician.namespace.v1"
private let CLINICIAN_NAME = "Dr. Y. Chen"   // adjustable; appears in the patient's consent screen

@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case boot
        case home
        case scanning
        case request(PatientQRPayload)
        case active(encounterId: String, request: EncounterRequest, baseUrl: String)
        case audit
    }

    @Published var screen: Screen = .boot
    @Published var recipient: String? = nil
    @Published var bootError: String? = nil
    @Published var seAvailable: Bool = SeAgeService.isAvailable()

    func boot() async {
        guard seAvailable else { return }
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
                    HomeView(
                        clinicianRecipient: r,
                        clinicianName: CLINICIAN_NAME,
                        onStartScan: { model.screen = .scanning },
                        onOpenAudit: { model.screen = .audit }
                    )
                }
            case .scanning:
                scanningWrapper
            case .request(let payload):
                if let r = model.recipient {
                    EncounterRequestView(
                        patient: payload,
                        clinicianRecipient: r,
                        clinicianName: CLINICIAN_NAME,
                        onSubmitted: { id, req, client in
                            model.screen = .active(encounterId: id, request: req, baseUrl: client.baseUrl)
                        },
                        onCancel: { model.screen = .home }
                    )
                }
            case .active(let encounterId, let request, let baseUrl):
                ActiveEncounterView(
                    encounterId: encounterId,
                    request: request,
                    client: RelayClient(baseUrl: baseUrl),
                    clinicianKeyTag: SE_KEY_TAG,
                    onEnd: { model.screen = .home }
                )
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
