// memory-oracle Patient — Phase 3c-iv
//
// Wires the full patient encounter flow: SE-bound identity (3b) + age v1
// encryption/decryption (3c-i + 3c-ii) + relay polling (3c-iii) + QR
// display + consent UI (this sub-phase).
//
// Screen flow:
//   boot → patient-identity (default home: QR + pending requests list)
//                ↓ tap a request
//          consent (approve = encrypt + POST; deny = audit-only)
//                ↓ done
//          patient-identity
//
// See: docs/plans/verum-phase-3c-five-substep-resequence-20260531.md

import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, ScrollView, Platform } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import SeAge from 'se-age';
import PatientIdentityScreen from './screens/PatientIdentity.js';
import ConsentScreen from './screens/Consent.js';
import { readAudit } from './lib/audit.js';

const SE_KEY_TAG = 'mo.patient.namespace.v1';

export default function App() {
  const [boot, setBoot] = useState(true);
  const [seAvailable, setSeAvailable] = useState(null);
  const [recipient, setRecipient] = useState(null);
  const [bootError, setBootError] = useState(null);

  const [screen, setScreen] = useState('home');   // 'home' | 'consent' | 'audit'
  const [selectedRequest, setSelectedRequest] = useState(null);
  const [auditLog, setAuditLog] = useState([]);

  // Boot: confirm SE, generate/load identity, prefetch audit log.
  useEffect(() => {
    (async () => {
      const available = SeAge.isAvailable();
      setSeAvailable(available);
      if (!available) {
        setBoot(false);
        return;
      }
      try {
        const r = await SeAge.getOrCreateIdentity(SE_KEY_TAG);
        setRecipient(r);
      } catch (e) {
        setBootError(e?.message ?? String(e));
      }
      setAuditLog(await readAudit());
      setBoot(false);
    })();
  }, []);

  async function refreshAudit() {
    setAuditLog(await readAudit());
  }

  // ── render ──────────────────────────────────────────────────────────────

  if (boot) {
    return (
      <View style={styles.fullCenter}>
        <Text style={styles.muted}>booting…</Text>
        <StatusBar style="auto" />
      </View>
    );
  }

  if (seAvailable === false) {
    return (
      <View style={styles.fullCenter}>
        <StatusBar style="auto" />
        <Text style={styles.title}>memory-oracle Patient</Text>
        <View style={styles.errorBox}>
          <Text style={styles.errorTitle}>Secure Enclave not available</Text>
          <Text style={styles.errorBody}>
            Requires real iPhone hardware (iPhone 5s+). The iOS Simulator
            does not have a Secure Enclave and cannot run this app.
          </Text>
        </View>
      </View>
    );
  }

  if (bootError) {
    return (
      <View style={styles.fullCenter}>
        <StatusBar style="auto" />
        <Text style={styles.title}>memory-oracle Patient</Text>
        <View style={styles.errorBox}>
          <Text style={styles.errorTitle}>Identity bootstrap failed</Text>
          <Text style={styles.errorBody}>{bootError}</Text>
        </View>
      </View>
    );
  }

  if (screen === 'consent' && selectedRequest) {
    return (
      <>
        <StatusBar style="auto" />
        <ConsentScreen
          request={selectedRequest}
          onDismiss={async () => {
            setSelectedRequest(null);
            setScreen('home');
            await refreshAudit();
          }}
        />
      </>
    );
  }

  if (screen === 'audit') {
    return (
      <>
        <StatusBar style="auto" />
        <ScrollView contentContainerStyle={styles.auditContainer}>
          <TouchableOpacity onPress={() => setScreen('home')} style={styles.backLink}>
            <Text style={styles.backText}>← back</Text>
          </TouchableOpacity>
          <Text style={styles.title}>Audit log</Text>
          <Text style={styles.muted}>{auditLog.length} entries (last 100 retained)</Text>
          {auditLog.slice(-50).reverse().map((e, i) => (
            <View key={i} style={styles.auditEntry}>
              <Text style={styles.auditTs}>{e.ts}</Text>
              <Text style={styles.auditEvent}>{e.event}</Text>
              {e.encounterId ? <Text style={styles.auditDetail}>encounter: {e.encounterId.slice(0, 8)}…</Text> : null}
              {e.clinicianName ? <Text style={styles.auditDetail}>clinician: {e.clinicianName}</Text> : null}
              {e.scopes ? <Text style={styles.auditDetail}>scopes: {e.scopes.join(', ')}</Text> : null}
            </View>
          ))}
        </ScrollView>
      </>
    );
  }

  // Default: home (patient identity + pending requests).
  return (
    <>
      <StatusBar style="auto" />
      <PatientIdentityScreen
        recipient={recipient}
        onSelectRequest={(req) => {
          setSelectedRequest(req);
          setScreen('consent');
        }}
        onOpenAudit={() => setScreen('audit')}
      />
    </>
  );
}

const styles = StyleSheet.create({
  fullCenter: {
    flex: 1,
    padding: 24,
    paddingTop: 80,
    backgroundColor: '#fff',
  },
  title: { fontSize: 26, fontWeight: '700', marginBottom: 8 },
  muted: { color: '#888', fontSize: 13, marginBottom: 8 },
  errorBox: {
    backgroundColor: '#fdecec',
    padding: 16,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#e8a0a0',
    marginTop: 16,
  },
  errorTitle: { fontSize: 15, fontWeight: '700', color: '#922', marginBottom: 6 },
  errorBody: { fontSize: 13, lineHeight: 20, color: '#622' },
  auditContainer: { padding: 24, paddingTop: 60, backgroundColor: '#fff', minHeight: '100%' },
  backLink: { marginBottom: 16 },
  backText: { color: '#0066cc', fontSize: 15 },
  auditEntry: {
    backgroundColor: '#f6f7f9',
    padding: 12,
    borderRadius: 8,
    marginVertical: 4,
    borderLeftWidth: 3,
    borderLeftColor: '#cce',
  },
  auditTs: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 10,
    color: '#999',
  },
  auditEvent: { fontSize: 14, fontWeight: '600', color: '#334', marginTop: 2 },
  auditDetail: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 11,
    color: '#666',
    marginTop: 2,
  },
});
