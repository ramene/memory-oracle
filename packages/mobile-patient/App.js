// memory-oracle Patient — Phase 3b
//
// Wired to the local `se-age` native module for Apple Secure Enclave-backed
// age recipients (age1se1...) with Face ID-gated ECDH.
//
// 3b deliverable: real Secure Enclave key generation + recipient display +
// Face ID-gated key-agreement smoke test. The "Test Face ID + ECDH" button
// performs ECDH with the patient's own recipient (self-pairing) — this is
// useless cryptographically but confirms the full SE → Face ID → shared
// secret path works end-to-end on the device.
//
// 3c will replace the self-pairing test with the real encounter handshake
// against the relay.
//
// See: .claude/plans/verum-phase-3-ios-faceid-dual-device-20260531.md

import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, ScrollView, Platform, Alert } from 'react-native';
import * as SecureStore from 'expo-secure-store';
import { StatusBar } from 'expo-status-bar';
import SeAge from 'se-age';

const AUDIT_LOG_KEY = 'mo.patient.audit.log';
const SE_KEY_TAG = 'mo.patient.namespace.v1';

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

function hex(bytes) {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export default function App() {
  const [stage, setStage] = useState('boot');
  const [seAvailable, setSeAvailable] = useState(null);
  const [recipient, setRecipient] = useState(null);
  const [lastSharedSecret, setLastSharedSecret] = useState(null);
  const [auditLog, setAuditLog] = useState([]);
  const [pendingRequests] = useState([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    (async () => {
      const available = SeAge.isAvailable();
      setSeAvailable(available);
      const log = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
      if (log) setAuditLog(JSON.parse(log));
      if (available) {
        const existing = await SeAge.getRecipient(SE_KEY_TAG);
        if (existing) setRecipient(existing);
      }
      setStage('ready');
    })();
  }, []);

  async function initializeIdentity() {
    setBusy(true);
    try {
      const r = await SeAge.getOrCreateIdentity(SE_KEY_TAG);
      setRecipient(r);
      const updated = await appendAudit({ event: 'se_identity_generated', recipient_prefix: r.slice(0, 16) });
      setAuditLog(updated);
    } catch (e) {
      Alert.alert('Identity generation failed', e?.message ?? String(e));
    } finally {
      setBusy(false);
    }
  }

  async function testFaceIdEcdh() {
    if (!recipient) return;
    setBusy(true);
    try {
      const shared = await SeAge.performKeyAgreement(
        SE_KEY_TAG,
        recipient,
        'Confirm Face ID — this is a self-pairing smoke test (3b)',
      );
      setLastSharedSecret(shared);
      const updated = await appendAudit({
        event: 'face_id_ecdh_smoketest_ok',
        shared_prefix: hex(shared).slice(0, 16),
      });
      setAuditLog(updated);
    } catch (e) {
      const code = e?.code ?? 'unknown';
      if (code === 'SeAgeUserCancelled') {
        const updated = await appendAudit({ event: 'face_id_cancelled' });
        setAuditLog(updated);
      } else {
        Alert.alert('Key agreement failed', `[${code}] ${e?.message ?? String(e)}`);
      }
    } finally {
      setBusy(false);
    }
  }

  if (stage === 'boot') {
    return (
      <View style={styles.container}>
        <Text style={styles.muted}>booting…</Text>
        <StatusBar style="auto" />
      </View>
    );
  }

  if (seAvailable === false) {
    return (
      <View style={styles.container}>
        <StatusBar style="auto" />
        <Text style={styles.title}>memory-oracle Patient</Text>
        <View style={styles.errorBox}>
          <Text style={styles.errorTitle}>Secure Enclave not available</Text>
          <Text style={styles.errorBody}>
            This app requires a real iPhone with a Secure Enclave (iPhone 5s
            or newer). It will not run in the iOS Simulator.
          </Text>
        </View>
      </View>
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <StatusBar style="auto" />
      <Text style={styles.title}>memory-oracle Patient</Text>
      <Text style={styles.subtitle}>Phase 3b · Secure Enclave wired</Text>

      <View style={styles.scaffoldNotice}>
        <Text style={styles.scaffoldNoticeTitle}>3b smoke-test build</Text>
        <Text style={styles.scaffoldNoticeBody}>
          Real Secure Enclave + Face ID are wired. The encounter handshake
          against the relay lands in 3c. The "Test Face ID + ECDH" button
          performs ECDH with this device's own recipient (self-pairing) —
          cryptographically useless but proves the SE → Face ID path works.
        </Text>
      </View>

      <Text style={styles.sectionHeader}>Patient identity</Text>
      {recipient ? (
        <View style={styles.recipientBox}>
          <Text style={styles.recipientLabel}>Your age recipient (Secure Enclave-bound):</Text>
          <Text style={styles.recipientValue} selectable>{recipient}</Text>
          <Text style={styles.muted}>
            Share this with a clinician's Mac via QR (3c). The private key
            never leaves this iPhone's Secure Enclave.
          </Text>
        </View>
      ) : (
        <TouchableOpacity
          style={[styles.btnPrimary, busy && styles.btnDisabled]}
          onPress={initializeIdentity}
          disabled={busy}
        >
          <Text style={styles.btnText}>{busy ? 'Generating…' : 'Generate Secure Enclave identity'}</Text>
        </TouchableOpacity>
      )}

      {recipient ? (
        <>
          <Text style={styles.sectionHeader}>Smoke test (3b)</Text>
          <TouchableOpacity
            style={[styles.btnPrimary, busy && styles.btnDisabled]}
            onPress={testFaceIdEcdh}
            disabled={busy}
          >
            <Text style={styles.btnText}>{busy ? 'Face ID…' : 'Test Face ID + ECDH (self-pair)'}</Text>
          </TouchableOpacity>
          {lastSharedSecret ? (
            <View style={styles.successBox}>
              <Text style={styles.successLabel}>ECDH succeeded — shared secret (truncated):</Text>
              <Text style={styles.successValue} selectable>
                {hex(lastSharedSecret).slice(0, 32)}…
              </Text>
              <Text style={styles.muted}>32 bytes total. In 3c this feeds HKDF for wrapping-key derivation.</Text>
            </View>
          ) : null}
        </>
      ) : null}

      <Text style={styles.sectionHeader}>Pending encounter requests</Text>
      {pendingRequests.length === 0 ? (
        <View style={styles.emptyBox}>
          <Text style={styles.emptyText}>
            None yet. 3c wires the relay so clinician scans of your QR appear here.
          </Text>
        </View>
      ) : null}

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
  recipientBox: {
    backgroundColor: '#f4f8ff',
    padding: 14,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#cdd9ee',
    marginVertical: 8,
  },
  recipientLabel: { fontSize: 12, color: '#446', fontWeight: '600', marginBottom: 6 },
  recipientValue: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 11,
    color: '#114',
    marginBottom: 6,
  },
  successBox: {
    backgroundColor: '#f0fbf0',
    padding: 12,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#bfe0bf',
    marginVertical: 8,
  },
  successLabel: { fontSize: 12, color: '#264', fontWeight: '600', marginBottom: 4 },
  successValue: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 11,
    color: '#163',
  },
  emptyBox: {
    backgroundColor: '#f6f7f9',
    padding: 16,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#dde0e6',
    marginBottom: 16,
  },
  emptyText: { color: '#667', fontSize: 14, lineHeight: 20 },
  errorBox: {
    backgroundColor: '#fdecec',
    padding: 16,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#e8a0a0',
    marginVertical: 12,
  },
  errorTitle: { fontSize: 15, fontWeight: '700', color: '#922', marginBottom: 6 },
  errorBody: { fontSize: 13, lineHeight: 20, color: '#622' },
  btnPrimary: {
    backgroundColor: '#0066cc',
    padding: 16,
    borderRadius: 10,
    alignItems: 'center',
    marginVertical: 8,
  },
  btnDisabled: { opacity: 0.5 },
  btnText: { color: '#fff', fontSize: 15, fontWeight: '600' },
  muted: { color: '#888', fontSize: 12, marginTop: 8, lineHeight: 16 },
  auditHeader: { fontSize: 14, fontWeight: '600', marginTop: 18, color: '#666' },
  auditEntry: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 11,
    color: '#888',
    marginTop: 3,
  },
});
