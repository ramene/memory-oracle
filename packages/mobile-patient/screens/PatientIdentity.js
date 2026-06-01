// Main patient screen: QR with own recipient + relay URL, plus a list
// of pending encounter requests. Tap a request → ConsentScreen.

import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View, Platform } from 'react-native';
import QRCode from 'react-native-qrcode-svg';
import { usePendingRequests } from '../hooks/usePendingRequests.js';
import { getRelayBaseUrl } from '../lib/relay.js';

export default function PatientIdentityScreen({ recipient, onSelectRequest, onOpenAudit }) {
  const relayBaseUrl = getRelayBaseUrl();
  const qrPayload = JSON.stringify({ v: 1, recipient, relay: relayBaseUrl });

  const { requests, loading, error, relayReachable, refetch } = usePendingRequests(recipient);

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.title}>memory-oracle Patient</Text>
      <Text style={styles.subtitle}>Phase 3c-iv · encounter UI wired</Text>

      <View style={styles.qrCard}>
        <Text style={styles.cardLabel}>Your patient QR</Text>
        <View style={styles.qrWrap}>
          <QRCode value={qrPayload} size={200} backgroundColor="#fff" />
        </View>
        <Text style={styles.cardHint}>Clinician scans this to request an encounter.</Text>
        <Text style={styles.recipient} selectable>{recipient}</Text>
        <Text style={styles.relayInfo}>
          relay: {relayBaseUrl}  {relayReachable === false ? '⚠ unreachable' : relayReachable ? '✓ reachable' : '…'}
        </Text>
      </View>

      <View style={styles.pendingHeader}>
        <Text style={styles.sectionHeader}>Pending requests ({requests.length})</Text>
        <TouchableOpacity onPress={refetch} disabled={loading}>
          <Text style={[styles.refreshBtn, loading && styles.muted]}>
            {loading ? '…' : 'refresh'}
          </Text>
        </TouchableOpacity>
      </View>

      {error ? (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>relay error: {error}</Text>
          <Text style={styles.muted}>auto-retrying every 5s when app is foregrounded</Text>
        </View>
      ) : null}

      {requests.length === 0 && !error ? (
        <View style={styles.emptyBox}>
          <Text style={styles.emptyText}>
            No pending encounter requests. When a clinician scans your QR, a
            request appears here for your approval.
          </Text>
        </View>
      ) : null}

      {requests.map(r => (
        <TouchableOpacity
          key={r.encounterId}
          style={styles.requestCard}
          onPress={() => onSelectRequest(r)}
        >
          <Text style={styles.requestClinician}>{r.clinicianName}</Text>
          <Text style={styles.requestScopes}>
            Requesting: {r.requestedScopes.join(', ')}
          </Text>
          <Text style={styles.requestTtl}>
            Valid for {Math.round(r.ttlSeconds / 60)} min · tap to review
          </Text>
        </TouchableOpacity>
      ))}

      <TouchableOpacity style={styles.auditLink} onPress={onOpenAudit}>
        <Text style={styles.auditLinkText}>View audit log →</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { padding: 24, paddingTop: 60, backgroundColor: '#fff', minHeight: '100%' },
  title: { fontSize: 26, fontWeight: '700', marginBottom: 2 },
  subtitle: { fontSize: 13, color: '#888', marginBottom: 22 },
  qrCard: {
    backgroundColor: '#f4f8ff',
    padding: 18,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#cdd9ee',
    alignItems: 'center',
    marginBottom: 20,
  },
  cardLabel: { fontSize: 14, fontWeight: '600', color: '#446', marginBottom: 12, alignSelf: 'flex-start' },
  qrWrap: { padding: 12, backgroundColor: '#fff', borderRadius: 8 },
  cardHint: { fontSize: 12, color: '#668', marginTop: 12, textAlign: 'center' },
  recipient: {
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 10,
    color: '#224',
    marginTop: 12,
    textAlign: 'center',
  },
  relayInfo: { fontSize: 11, color: '#668', marginTop: 8 },
  pendingHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  sectionHeader: { fontSize: 16, fontWeight: '600', marginTop: 8, marginBottom: 8, color: '#333' },
  refreshBtn: { color: '#0066cc', fontSize: 14, fontWeight: '500' },
  muted: { color: '#999' },
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
    padding: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#e8a0a0',
    marginBottom: 12,
  },
  errorText: { color: '#722', fontSize: 13 },
  requestCard: {
    backgroundColor: '#fffaf0',
    padding: 16,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: '#e8c890',
    marginBottom: 10,
  },
  requestClinician: { fontSize: 16, fontWeight: '700', color: '#552' },
  requestScopes: { fontSize: 13, color: '#664', marginTop: 4 },
  requestTtl: { fontSize: 12, color: '#886', marginTop: 6 },
  auditLink: { padding: 14, alignItems: 'center', marginTop: 16 },
  auditLinkText: { color: '#0066cc', fontSize: 14 },
});
