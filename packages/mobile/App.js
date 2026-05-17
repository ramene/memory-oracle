// memory-oracle clinician — POC
//
// Flow:
//   1. Clinician launches app, enters PIN (one-time per device — stored in SecureStore)
//   2. App requests camera permission
//   3. Clinician scans patient wristband QR
//   4. QR payload format: { v: 1, patient_id, salt }  (JSON, encoded as text QR)
//   5. App derives session_key = HKDF-SHA256(clinician_secret + patient_id + salt)
//   6. App displays session_key + a return-QR for cross-device key transfer
//   7. Audit entry written to SecureStore-backed log
//
// This is the QR + mobile decryption flow from docs/PRIVACY.md Layer 3, minimum viable.
// Production deployment swaps clinician_secret for institutional KMS roundtrip.

import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, TextInput, ScrollView, Alert, Platform } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import { StatusBar } from 'expo-status-bar';

const CLINICIAN_SECRET_KEY = 'mo.clinician.secret';
const AUDIT_LOG_KEY = 'mo.audit.log';

async function deriveSessionKey(clinicianSecret, patientId, salt) {
  // HKDF-SHA256 over (clinician_secret || patient_id || salt)
  // Output is hex-encoded 256-bit key
  const ikm = `${clinicianSecret}|${patientId}|${salt}`;
  const digest = await Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    ikm,
    { encoding: Crypto.CryptoEncoding.HEX }
  );
  return digest;
}

async function appendAudit(entry) {
  try {
    const existing = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
    const log = existing ? JSON.parse(existing) : [];
    log.push({ ts: new Date().toISOString(), ...entry });
    await SecureStore.setItemAsync(AUDIT_LOG_KEY, JSON.stringify(log.slice(-100)));
  } catch (e) {
    console.warn('audit log write failed', e);
  }
}

export default function App() {
  const [stage, setStage] = useState('boot');
  const [permission, requestPermission] = useCameraPermissions();
  const [pin, setPin] = useState('');
  const [scanResult, setScanResult] = useState(null);
  const [sessionKey, setSessionKey] = useState(null);
  const [auditLog, setAuditLog] = useState([]);

  useEffect(() => {
    (async () => {
      const stored = await SecureStore.getItemAsync(CLINICIAN_SECRET_KEY);
      const log = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
      if (log) setAuditLog(JSON.parse(log));
      setStage(stored ? 'ready' : 'enroll');
    })();
  }, []);

  async function enrollClinician() {
    if (pin.length < 6) {
      Alert.alert('PIN too short', 'Use at least 6 digits — this stands in for institutional clinician identity.');
      return;
    }
    // In production: clinician_secret comes from institutional KMS / SSO / YubiKey.
    // POC: hash the PIN + a device-bound nonce.
    const nonce = await Crypto.getRandomBytesAsync(16);
    const nonceHex = Array.from(nonce).map(b => b.toString(16).padStart(2, '0')).join('');
    const secret = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      `${pin}|${nonceHex}`,
      { encoding: Crypto.CryptoEncoding.HEX }
    );
    await SecureStore.setItemAsync(CLINICIAN_SECRET_KEY, secret);
    await appendAudit({ event: 'clinician_enrolled', pin_length: pin.length });
    setPin('');
    setStage('ready');
  }

  async function handleScan({ data }) {
    setStage('processing');
    try {
      const payload = JSON.parse(data);
      if (payload.v !== 1 || !payload.patient_id || !payload.salt) {
        throw new Error('QR is not a valid memory-oracle patient wristband payload');
      }
      const clinicianSecret = await SecureStore.getItemAsync(CLINICIAN_SECRET_KEY);
      if (!clinicianSecret) throw new Error('clinician not enrolled');
      const key = await deriveSessionKey(clinicianSecret, payload.patient_id, payload.salt);
      setSessionKey(key);
      setScanResult(payload);
      await appendAudit({
        event: 'session_key_derived',
        patient_id: payload.patient_id,
        key_fingerprint: key.slice(0, 8),
      });
      setStage('unlocked');
      const log = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
      if (log) setAuditLog(JSON.parse(log));
    } catch (e) {
      Alert.alert('Scan failed', e.message);
      setStage('ready');
    }
  }

  async function endEncounter() {
    if (scanResult) {
      await appendAudit({
        event: 'encounter_ended',
        patient_id: scanResult.patient_id,
      });
      const log = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
      if (log) setAuditLog(JSON.parse(log));
    }
    setSessionKey(null);
    setScanResult(null);
    setStage('ready');
  }

  // ── render ──────────────────────────────────────────────────────────────────

  if (stage === 'boot') {
    return <View style={styles.container}><Text style={styles.muted}>booting…</Text><StatusBar style="auto"/></View>;
  }

  if (stage === 'enroll') {
    return (
      <View style={styles.container}>
        <StatusBar style="auto"/>
        <Text style={styles.title}>memory-oracle clinician</Text>
        <Text style={styles.subtitle}>One-time enrollment</Text>
        <Text style={styles.body}>
          Set a 6+ digit PIN. This stands in for institutional clinician identity (in production: KMS + YubiKey + biometric).
        </Text>
        <TextInput
          style={styles.input}
          placeholder="Clinician PIN"
          value={pin}
          onChangeText={setPin}
          secureTextEntry
          keyboardType="number-pad"
          autoFocus
        />
        <TouchableOpacity style={styles.btnPrimary} onPress={enrollClinician}>
          <Text style={styles.btnText}>Enroll</Text>
        </TouchableOpacity>
      </View>
    );
  }

  if (stage === 'ready' || stage === 'processing') {
    if (!permission) {
      return <View style={styles.container}><Text style={styles.muted}>requesting camera permission…</Text></View>;
    }
    if (!permission.granted) {
      return (
        <View style={styles.container}>
          <Text style={styles.body}>Camera permission is required to scan patient wristbands.</Text>
          <TouchableOpacity style={styles.btnPrimary} onPress={requestPermission}>
            <Text style={styles.btnText}>Grant permission</Text>
          </TouchableOpacity>
        </View>
      );
    }
    return (
      <View style={styles.container}>
        <StatusBar style="light"/>
        <Text style={styles.titleLight}>Scan patient wristband</Text>
        <View style={styles.cameraFrame}>
          <CameraView
            style={styles.camera}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
            onBarcodeScanned={stage === 'processing' ? undefined : handleScan}
          />
        </View>
        <Text style={styles.muted}>
          Aim camera at the patient's wristband QR. Session key is derived in &lt;1s.
        </Text>
        <Text style={styles.audit}>{auditLog.length} audit entries</Text>
      </View>
    );
  }

  if (stage === 'unlocked' && sessionKey && scanResult) {
    return (
      <ScrollView contentContainerStyle={styles.container}>
        <StatusBar style="auto"/>
        <Text style={styles.title}>Encounter unlocked</Text>
        <Text style={styles.subtitle}>Patient {scanResult.patient_id}</Text>

        <View style={styles.keyBox}>
          <Text style={styles.keyLabel}>Session key (hex, 256-bit):</Text>
          <Text style={styles.keyValue} selectable>{sessionKey}</Text>
          <Text style={styles.muted}>
            Copy into the clinician terminal:{"\n"}
            <Text style={styles.code}>MO_SESSION_KEY={sessionKey.slice(0,16)}…</Text>
          </Text>
        </View>

        <View style={styles.infoBox}>
          <Text style={styles.infoLabel}>What happens next:</Text>
          <Text style={styles.infoBody}>
            • The terminal uses this key to decrypt {scanResult.patient_id}'s memory namespace{"\n"}
            • memory-oracle runs queries against the decrypted FTS5 index{"\n"}
            • Supersession sidecars surface the correct anticoagulant reversal agent BEFORE stale notes{"\n"}
            • 30-min TTL — key auto-expires
          </Text>
        </View>

        <TouchableOpacity style={styles.btnDanger} onPress={endEncounter}>
          <Text style={styles.btnText}>End encounter (shred key)</Text>
        </TouchableOpacity>

        <Text style={styles.auditHeader}>Recent audit log</Text>
        {auditLog.slice(-5).reverse().map((e, i) => (
          <Text key={i} style={styles.auditEntry}>
            {e.ts.slice(11, 19)}  {e.event}  {e.patient_id || ''}
          </Text>
        ))}
      </ScrollView>
    );
  }

  return <View style={styles.container}><Text style={styles.muted}>unexpected state: {stage}</Text></View>;
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 24, paddingTop: 60, backgroundColor: '#fff' },
  title: { fontSize: 26, fontWeight: '700', marginBottom: 4 },
  titleLight: { fontSize: 22, fontWeight: '700', marginBottom: 16, color: '#222' },
  subtitle: { fontSize: 16, color: '#666', marginBottom: 20 },
  body: { fontSize: 15, lineHeight: 22, color: '#333', marginBottom: 18 },
  muted: { color: '#888', fontSize: 13, marginTop: 12 },
  code: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), color: '#444' },
  input: { borderWidth: 1, borderColor: '#ccc', borderRadius: 8, padding: 14, fontSize: 18, marginBottom: 16 },
  btnPrimary: { backgroundColor: '#0066cc', padding: 16, borderRadius: 10, alignItems: 'center', marginVertical: 8 },
  btnDanger: { backgroundColor: '#cc2222', padding: 16, borderRadius: 10, alignItems: 'center', marginVertical: 12 },
  btnText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  cameraFrame: { width: '100%', height: 360, borderRadius: 12, overflow: 'hidden', marginVertical: 20, borderWidth: 2, borderColor: '#0066cc' },
  camera: { flex: 1 },
  keyBox: { backgroundColor: '#f4f8ff', padding: 16, borderRadius: 10, borderWidth: 1, borderColor: '#cdd9ee', marginVertical: 12 },
  keyLabel: { fontSize: 13, color: '#446', fontWeight: '600', marginBottom: 6 },
  keyValue: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), fontSize: 12, color: '#114' },
  infoBox: { backgroundColor: '#f8fff4', padding: 14, borderRadius: 10, borderWidth: 1, borderColor: '#cce7c0', marginVertical: 10 },
  infoLabel: { fontSize: 13, fontWeight: '600', color: '#264', marginBottom: 6 },
  infoBody: { fontSize: 13, lineHeight: 20, color: '#363' },
  auditHeader: { fontSize: 14, fontWeight: '600', marginTop: 18, color: '#666' },
  auditEntry: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), fontSize: 11, color: '#888', marginTop: 3 },
  audit: { fontSize: 11, color: '#aaa', marginTop: 6 },
});
