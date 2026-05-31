// memory-oracle Patient — Phase 3a SCAFFOLD
//
// Phase 3 of the Verum biometric-unlock rollout (LNCS §7.4 dual-device demo).
// This sub-phase (3a) is the rename + scaffold only — it compiles and runs but
// has no encounter handshake or Secure Enclave wiring yet.
//
// What this app will eventually do (3b + 3c):
//   1. On launch, list any pending EncounterRequests received from the relay
//      (clinician's iPad scans the patient's QR → relay forwards request here)
//   2. Patient taps a request → app shows clinician identity + requested scopes + TTL
//   3. Patient confirms → Face ID prompt (gated by kSecAttrAccessControl in the
//      native SE module, NOT just expo-local-authentication)
//   4. On success, the native module:
//        a. uses the Secure Enclave private key to perform ECDH against the
//           clinician's public recipient
//        b. derives a wrapped session key for each requested scope
//        c. returns the wrapped keys to JS
//   5. App POSTs an EncounterApproval (with the wrapped keys) back to the relay
//   6. Audit entry written to SecureStore-backed log
//
// 3a (this file) shows only stages 1 (with empty pending list) and the audit log.
// The Face ID button is a placeholder that records a "would-fire" audit entry —
// no real key operations happen yet.
//
// See: .claude/plans/verum-phase-3-ios-faceid-dual-device-20260531.md

import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, ScrollView, Platform } from 'react-native';
import * as SecureStore from 'expo-secure-store';
import { StatusBar } from 'expo-status-bar';

const AUDIT_LOG_KEY = 'mo.patient.audit.log';

async function appendAudit(entry) {
  try {
    const existing = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
    const log = existing ? JSON.parse(existing) : [];
    log.push({ ts: new Date().toISOString(), ...entry });
    await SecureStore.setItemAsync(AUDIT_LOG_KEY, JSON.stringify(log.slice(-100)));
    return log;
  } catch (e) {
    console.warn('audit log write failed', e);
    return [];
  }
}

export default function App() {
  const [stage, setStage] = useState('boot');
  const [auditLog, setAuditLog] = useState([]);
  // Pending requests will arrive from the relay in 3c. For now: always empty.
  const [pendingRequests] = useState([]);

  useEffect(() => {
    (async () => {
      const log = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
      if (log) setAuditLog(JSON.parse(log));
      setStage('ready');
    })();
  }, []);

  async function simulateApproval() {
    // 3a placeholder: records intent only. 3b replaces this with a native
    // SE module call that genuinely gates on Face ID.
    const updated = await appendAudit({
      event: 'face_id_placeholder_fired',
      note: 'Phase 3a scaffold — no real Face ID, no real key release',
    });
    setAuditLog(updated);
  }

  if (stage === 'boot') {
    return (
      <View style={styles.container}>
        <Text style={styles.muted}>booting…</Text>
        <StatusBar style="auto" />
      </View>
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <StatusBar style="auto" />
      <Text style={styles.title}>memory-oracle Patient</Text>
      <Text style={styles.subtitle}>Phase 3a scaffold</Text>

      <View style={styles.scaffoldNotice}>
        <Text style={styles.scaffoldNoticeTitle}>This is a scaffold build.</Text>
        <Text style={styles.scaffoldNoticeBody}>
          Phase 3a (rename + scaffold) is complete. Phase 3b adds the native
          Secure Enclave module + real Face ID gating. Phase 3c wires the
          encounter-handshake protocol against the relay.
        </Text>
      </View>

      <Text style={styles.sectionHeader}>Pending requests</Text>
      {pendingRequests.length === 0 ? (
        <View style={styles.emptyBox}>
          <Text style={styles.emptyText}>
            No pending encounter requests. When a clinician scans your QR, a
            request will appear here for your approval.
          </Text>
        </View>
      ) : null}

      <TouchableOpacity style={styles.btnPrimary} onPress={simulateApproval}>
        <Text style={styles.btnText}>(scaffold) Record placeholder approval</Text>
      </TouchableOpacity>

      <Text style={styles.auditHeader}>Recent audit log ({auditLog.length} entries)</Text>
      {auditLog.slice(-10).reverse().map((e, i) => (
        <Text key={i} style={styles.auditEntry}>
          {e.ts.slice(11, 19)}  {e.event}
        </Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 24, paddingTop: 60, backgroundColor: '#fff' },
  title: { fontSize: 26, fontWeight: '700', marginBottom: 4 },
  subtitle: { fontSize: 14, color: '#888', marginBottom: 24 },
  sectionHeader: { fontSize: 16, fontWeight: '600', marginTop: 18, marginBottom: 8, color: '#444' },
  scaffoldNotice: {
    backgroundColor: '#fff8e1',
    padding: 14,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#ffd966',
    marginBottom: 18,
  },
  scaffoldNoticeTitle: { fontSize: 14, fontWeight: '700', color: '#664', marginBottom: 6 },
  scaffoldNoticeBody: { fontSize: 13, lineHeight: 19, color: '#553' },
  emptyBox: {
    backgroundColor: '#f6f7f9',
    padding: 16,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#dde0e6',
    marginBottom: 16,
  },
  emptyText: { color: '#667', fontSize: 14, lineHeight: 20 },
  btnPrimary: {
    backgroundColor: '#0066cc',
    padding: 16,
    borderRadius: 10,
    alignItems: 'center',
    marginVertical: 12,
  },
  btnText: { color: '#fff', fontSize: 15, fontWeight: '600' },
  muted: { color: '#888', fontSize: 13, marginTop: 12 },
  auditHeader: { fontSize: 14, fontWeight: '600', marginTop: 18, color: '#666' },
  auditEntry: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 11,
    color: '#888',
    marginTop: 3,
  },
});
