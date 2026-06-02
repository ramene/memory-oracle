// Consent screen for a single EncounterRequest. Shows clinician identity,
// requested scopes, and TTL with a live countdown. Approve fires the
// encryption + relay-submit flow (no Face ID prompt — Face ID only gates
// SE private-key operations, and encryption only uses public keys).
// Deny logs an audit entry; the encounter expires naturally on the relay.

import React, { useEffect, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, TouchableOpacity, View, Alert, Platform } from 'react-native';
import { approveEncounter, denyEncounter } from '../lib/approveEncounter.js';

export default function ConsentScreen({ request, onDismiss }) {
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null); // 'approved' | 'denied' | null
  const [error, setError] = useState(null);
  const [secondsLeft, setSecondsLeft] = useState(request.ttlSeconds);

  useEffect(() => {
    const issuedAt = new Date(request.issuedAt).getTime();
    const expiresAt = issuedAt + request.ttlSeconds * 1000;
    const tick = () => {
      const left = Math.max(0, Math.round((expiresAt - Date.now()) / 1000));
      setSecondsLeft(left);
    };
    tick();
    const interval = setInterval(tick, 1000);
    return () => clearInterval(interval);
  }, [request.issuedAt, request.ttlSeconds]);

  const expired = secondsLeft <= 0;

  async function handleApprove() {
    setBusy(true);
    setError(null);
    try {
      await approveEncounter(request);
      setResult('approved');
    } catch (e) {
      setError(e?.message ?? String(e));
    } finally {
      setBusy(false);
    }
  }

  async function handleDeny() {
    setBusy(true);
    setError(null);
    try {
      await denyEncounter(request);
      setResult('denied');
    } catch (e) {
      setError(e?.message ?? String(e));
    } finally {
      setBusy(false);
    }
  }

  if (result) {
    return (
      <View style={styles.container}>
        <Text style={styles.title}>
          {result === 'approved' ? 'Approved ✓' : 'Denied'}
        </Text>
        <Text style={styles.bodyText}>
          {result === 'approved'
            ? `Wrapped session keys for ${request.requestedScopes.length} scope(s) sent to ${request.clinicianName}. They are valid for ${Math.round(request.ttlSeconds / 60)} minutes.`
            : `${request.clinicianName} will not be able to retrieve a session key for this encounter. The relay entry expires naturally.`}
        </Text>
        <TouchableOpacity style={styles.btnPrimary} onPress={onDismiss}>
          <Text style={styles.btnText}>Done</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <TouchableOpacity onPress={onDismiss} style={styles.backLink} disabled={busy}>
        <Text style={styles.backText}>← back</Text>
      </TouchableOpacity>

      <Text style={styles.title}>Encounter request</Text>

      <View style={styles.identityCard}>
        <Text style={styles.identityLabel}>From</Text>
        <Text style={styles.identityName}>{request.clinicianName}</Text>
        <Text style={styles.identityRecipient} selectable>
          {request.clinicianRecipient}
        </Text>
      </View>

      <View style={styles.scopesCard}>
        <Text style={styles.scopesLabel}>Requesting access to</Text>
        {request.requestedScopes.map(s => (
          <View key={s} style={styles.scopeChip}>
            <Text style={styles.scopeChipText}>{s}</Text>
          </View>
        ))}
      </View>

      <View style={styles.ttlCard}>
        <Text style={styles.ttlLabel}>Encounter valid for</Text>
        <Text style={[styles.ttlValue, expired && styles.ttlExpired]}>
          {expired ? 'expired' : formatTtl(secondsLeft)}
        </Text>
      </View>

      {error ? (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>{error}</Text>
        </View>
      ) : null}

      {expired ? (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>This request has expired. Ask the clinician to send a new one.</Text>
        </View>
      ) : null}

      <TouchableOpacity
        style={[styles.btnApprove, (busy || expired) && styles.btnDisabled]}
        onPress={handleApprove}
        disabled={busy || expired}
      >
        {busy ? <ActivityIndicator color="#fff" /> : <Text style={styles.btnText}>Approve</Text>}
      </TouchableOpacity>

      <TouchableOpacity
        style={[styles.btnDeny, busy && styles.btnDisabled]}
        onPress={handleDeny}
        disabled={busy}
      >
        <Text style={styles.btnText}>Deny</Text>
      </TouchableOpacity>

      <Text style={styles.fineprint}>
        Approving releases time-limited session keys to {request.clinicianName} for the scope(s) above.
        The clinician's device decrypts the keys with their own Face ID / Touch ID. Your private key
        never leaves this device's Secure Enclave.
      </Text>
    </ScrollView>
  );
}

function formatTtl(seconds) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}m ${String(s).padStart(2, '0')}s`;
}

const styles = StyleSheet.create({
  container: { padding: 24, paddingTop: 60, backgroundColor: '#fff', minHeight: '100%' },
  backLink: { marginBottom: 16 },
  backText: { color: '#0066cc', fontSize: 15 },
  title: { fontSize: 24, fontWeight: '700', marginBottom: 18 },
  identityCard: { backgroundColor: '#f4f8ff', padding: 16, borderRadius: 10, borderWidth: 1, borderColor: '#cdd9ee', marginBottom: 12 },
  identityLabel: { fontSize: 12, color: '#446', fontWeight: '600', marginBottom: 4 },
  identityName: { fontSize: 18, fontWeight: '700', color: '#224', marginBottom: 6 },
  identityRecipient: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), fontSize: 10, color: '#446' },
  scopesCard: { backgroundColor: '#f8fff4', padding: 16, borderRadius: 10, borderWidth: 1, borderColor: '#cce7c0', marginBottom: 12 },
  scopesLabel: { fontSize: 12, color: '#264', fontWeight: '600', marginBottom: 8 },
  scopeChip: { backgroundColor: '#fff', borderRadius: 14, paddingHorizontal: 10, paddingVertical: 5, marginRight: 6, marginBottom: 4, borderWidth: 1, borderColor: '#b8d8a8', alignSelf: 'flex-start' },
  scopeChipText: { fontSize: 13, color: '#363' },
  ttlCard: { padding: 14, alignItems: 'center', marginBottom: 16 },
  ttlLabel: { fontSize: 12, color: '#666' },
  ttlValue: { fontSize: 28, fontWeight: '700', color: '#224', marginTop: 4 },
  ttlExpired: { color: '#c44' },
  errorBox: { backgroundColor: '#fdecec', padding: 12, borderRadius: 8, borderWidth: 1, borderColor: '#e8a0a0', marginBottom: 12 },
  errorText: { color: '#722', fontSize: 13 },
  btnApprove: { backgroundColor: '#3a9a48', padding: 18, borderRadius: 10, alignItems: 'center', marginBottom: 10 },
  btnDeny: { backgroundColor: '#c44', padding: 16, borderRadius: 10, alignItems: 'center', marginBottom: 16 },
  btnPrimary: { backgroundColor: '#0066cc', padding: 16, borderRadius: 10, alignItems: 'center', marginTop: 24 },
  btnDisabled: { opacity: 0.5 },
  btnText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  fineprint: { fontSize: 11, color: '#888', lineHeight: 16, marginTop: 8 },
  bodyText: { fontSize: 14, lineHeight: 20, color: '#333', marginBottom: 16 },
});
