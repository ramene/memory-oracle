// EBRAlertView.swift
//
// AI Overview-styled alert sheet (Google's AI Overview pattern, per
// operator's choice 3b): TL;DR header, multi-paragraph explanation,
// expandable Sources callout showing the citation chain. Framed as
// DECISION SUPPORT — surfaces what was already in the citation card,
// doesn't render clinical opinion.
//
// Two action buttons:
//   - "Acknowledge & withdraw"  — clinician accepts the alert, no entry
//   - "Override (document reason)" — clinician proceeds anyway; logs
//                                     an override audit entry with a
//                                     required justification text

import SwiftUI

struct EBRAlertView: View {
    let result: EBRAlertResult
    var onAcknowledge: () -> Void
    var onOverride: (String) -> Void   // override reason text
    var onDismiss: () -> Void

    @State private var showSources = false
    @State private var showOverrideForm = false
    @State private var overrideReason = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    severityBanner
                    if let ai = result.aiOverview {
                        tldrCard(ai)
                        explanationCard(ai)
                        sourcesCallout(ai)
                    }
                    if let card = result.citationCard {
                        citationCardDetails(card)
                    }
                    actionButtons
                    if showOverrideForm {
                        overrideForm
                    }
                    framingDisclaimer
                }
                .padding(20)
            }
            .navigationTitle("EBR Alert")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Close") { onDismiss() })
        }
    }

    // MARK: - subviews

    private var severityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.severity == "critical" ? "Critical conflict" : "Conflict detected")
                    .font(.headline)
                if let kind = result.conflictKind {
                    Text(kind.replacingOccurrences(of: "-", with: " ").capitalized)
                        .font(.caption)
                        .opacity(0.9)
                }
            }
            Spacer()
        }
        .foregroundColor(.white)
        .padding(14)
        .background(result.severity == "critical"
                    ? Color(red: 0.7, green: 0.2, blue: 0.2)
                    : Color(red: 0.85, green: 0.55, blue: 0.15))
        .cornerRadius(10)
    }

    private func tldrCard(_ ai: AIOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.7))
                Text("AI Overview").font(.caption).fontWeight(.semibold)
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.7))
                Spacer()
            }
            Text(ai.tldr)
                .font(.headline)
                .foregroundColor(Color(red: 0.13, green: 0.13, blue: 0.27))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.96, green: 0.96, blue: 1.0))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.78, green: 0.78, blue: 0.95), lineWidth: 1))
        .cornerRadius(10)
    }

    private func explanationCard(_ ai: AIOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Explanation").font(.caption).fontWeight(.semibold)
                .foregroundColor(.secondary)
            // Renders the multi-paragraph explanation. Markdown-light:
            // **bold** spans are converted via AttributedString.
            if let attributed = try? AttributedString(markdown: ai.explanation) {
                Text(attributed)
                    .font(.body)
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.27))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ai.explanation)
                    .font(.body)
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.27))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .cornerRadius(10)
    }

    private func sourcesCallout(_ ai: AIOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.closed").foregroundColor(.secondary)
                Text("Sources (\(ai.sources.count))").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button(action: { showSources.toggle() }) {
                    Image(systemName: showSources ? "chevron.up" : "chevron.down")
                        .foregroundColor(.blue)
                }
            }
            if showSources {
                ForEach(ai.sources) { src in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(src.label).font(.caption).fontWeight(.semibold)
                            .foregroundColor(Color(red: 0.07, green: 0.4, blue: 0.65))
                        if let t = src.text {
                            Text(t)
                                .font(.system(size: 12, design: .serif))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let current = src.currentAssertion {
                            Text("→ now: \(current)")
                                .font(.caption)
                                .foregroundColor(Color(red: 0.13, green: 0.4, blue: 0.13))
                        }
                        if let mtime = src.mtime {
                            Text(mtime)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.99, blue: 0.97))
        .cornerRadius(10)
    }

    private func citationCardDetails(_ card: CitationCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Citation card").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
            HStack {
                Text("scope:").font(.caption).foregroundColor(.secondary)
                Text(card.scope).font(.caption).fontWeight(.semibold)
            }
            if let current = card.currentAssertion {
                Text("current: \(current)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.13, green: 0.4, blue: 0.13))
            }
            if let policy = card.policy {
                Text("policy: \(policy)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let chain = card.supersessionChain, !chain.isEmpty {
                Text("\(chain.count) amendment(s) in chain").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.97, blue: 0.94))
        .cornerRadius(10)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: { onAcknowledge() }) {
                Text("Acknowledge & withdraw")
                    .foregroundColor(.white).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(red: 0.23, green: 0.6, blue: 0.28))
                    .cornerRadius(10)
            }
            Button(action: { showOverrideForm.toggle() }) {
                Text("Override (document reason)")
                    .foregroundColor(.red).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red, lineWidth: 1))
            }
        }
    }

    private var overrideForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Override reason (required)")
                .font(.caption).fontWeight(.semibold)
            TextEditor(text: $overrideReason)
                .frame(minHeight: 80)
                .padding(8)
                .background(Color(red: 0.97, green: 0.97, blue: 0.98))
                .cornerRadius(8)
            Button(action: { onOverride(overrideReason.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                Text("Override anyway")
                    .foregroundColor(.white).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(overrideReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.gray : Color.red)
                    .cornerRadius(10)
            }
            .disabled(overrideReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .background(Color(red: 1.0, green: 0.96, blue: 0.96))
        .cornerRadius(10)
    }

    private var framingDisclaimer: some View {
        Text("Decision support — surfacing the patient's existing record. Not a clinical AI judgment. Clinician retains authority.")
            .font(.caption2)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}
