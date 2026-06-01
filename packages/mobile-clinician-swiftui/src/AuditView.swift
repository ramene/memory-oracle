// AuditView.swift  (clinician)

import SwiftUI

struct AuditView: View {
    var onDismiss: () -> Void

    @State private var entries: [AuditEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onDismiss) {
                    Text("← back")
                        .font(.callout).foregroundColor(.blue)
                }
                .padding(.top, 30)

                Text("Audit log").font(.title).fontWeight(.bold)
                Text("\(entries.count) entries (last 100 retained)")
                    .font(.caption).foregroundColor(.secondary)

                ForEach(Array(entries.suffix(50).reversed())) { e in
                    entryCard(e)
                }
            }
            .padding(24)
        }
        .onAppear { entries = AuditStore.read() }
    }

    private func entryCard(_ e: AuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(e.ts).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            Text(e.event).font(.subheadline).fontWeight(.semibold)
                .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.27))
            if let id = e.encounterId {
                Text("encounter: \(String(id.prefix(8)))…")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            if let scopes = e.scopes, !scopes.isEmpty {
                Text("scopes: \(scopes.joined(separator: ", "))")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            if let n = e.note {
                Text(n).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .overlay(Rectangle().frame(width: 3)
            .foregroundColor(Color(red: 0.07, green: 0.4, blue: 0.65)), alignment: .leading)
        .cornerRadius(8)
    }
}
