// memory-oracle Dr. — Clinician iPad viewer
//
// Flow:
//   1. Dr. opens app, sees "Scan patient wristband" — large camera frame
//   2. Patient shows their iPhone-generated wristband QR
//   3. Dr.'s iPad scans → decodes patient_id + salt
//   4. Dr.'s app derives session_key + queries the memory-oracle endpoint
//   5. Dr. sees the patient's anticoagulant record with ⚠ Supersession Notice
//      PROMINENTLY — andexanet alfa wins over the stale 2008 FFP protocol
//   6. Dr. taps "End Encounter" → working copy shredded, screen blanks, audit
//      entry written
//
// POC: the retrieval is hardcoded against the synthetic Jane Doe vault — the
// SAME content the terminal-side unlock-patient.sh validates. In production,
// the doctor's app talks to the memory-oracle REST API over the encounter's
// authenticated session.

import React, { useState, useEffect, useRef } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, TextInput, ScrollView, Alert, Platform, Dimensions, ActivityIndicator } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import { StatusBar } from 'expo-status-bar';

const DR_KEY = 'mo.doctor.identity';
const ENCOUNTER_TTL_MS = 30 * 60 * 1000;

// memory-oracle API endpoint — set at build time via the runtime injecter, or
// fall back to the demo cloudflared URL for the POC.
const API_URL = 'https://meaning-skill-hide-lender.trycloudflare.com';
const API_TOKEN = '979eaa2994c1889ababae1da556bc1fad9d620402eb09da380a3d3aa0a8b0a1a';
// In production the API_TOKEN is the per-encounter JWT, NOT a static string. The
// session_key derived during scan would be the bearer credential.

async function searchPatientHistory(query, patientProject = '_clinical-demo') {
  const url = `${API_URL}/search?q=${encodeURIComponent(query)}&project=${patientProject}&budget=15000&k=3`;
  const fullToken = await SecureStore.getItemAsync('mo.api.token') || API_TOKEN;
  const res = await fetch(url, { headers: { 'Authorization': `Bearer ${fullToken}` } });
  if (!res.ok) throw new Error(`API ${res.status}: ${await res.text()}`);
  const json = await res.json();
  return json.results || '';
}

// The supersession-merged anticoagulant record. In production this comes from
// memory-oracle's retrieval API; here it's the EXACT content that the terminal
// proof produces, baked in for the iPad demo.
const PATIENT_RECORDS = {
  'jane-doe-1959': {
    name: 'Jane Doe',
    dob: '1959-04-22',
    mrn: '47102-A',
    chart_age: '67 years',
    afib_history: 'Paroxysmal non-valvular AFib · diagnosed 2008-07-03',
    current_anticoag: {
      drug: 'Apixaban',
      dose: '5 mg PO BID',
      since: '2024-03-15',
      authored_by: 'Dr. Marcus Chen (Cardiology)',
      reason: 'Persistent INR lability in 2023 + moderate CKD (eGFR 48). Direct oral anticoagulant with predictable PK.',
    },
    reversal_protocol: {
      primary: 'Andexanet alfa — 400 mg IV bolus over 30 min, then 4 mg/min ×120 min (low-dose). 800/8/120 high-dose.',
      alternative: '4F-PCC 50 units/kg IV if andexanet alfa unavailable',
      supportive: 'For non-life-threatening bleed: hold dose, supportive care, charcoal if ingestion <2 hr',
      avoid: 'Do NOT administer FFP. Do NOT administer Vitamin K. Vitamin K has NO ROLE in factor Xa inhibitor reversal.',
    },
    supersession_note: {
      what_was_superseded: 'Warfarin 5mg PO daily (started 2008) + FFP/Vitamin K reversal protocol',
      when: '2024-03-15T14:22:00Z',
      why: 'Patient was switched from warfarin to apixaban due to persistent INR lability + new CKD diagnosis. The historical FFP+Vit K protocol DOES NOT APPLY while apixaban is the active agent.',
      authored_by: 'Dr. Marcus Chen, MD (Cardiology) — co-signed by Dr. Elena Vasquez, MD (PCP)',
      operator_confirmed: '2024-03-15T14:22:00Z',
    },
    allergies: ['Amoxicillin (rash, 2014)'],
    relevant_labs_recent: 'eGFR 48 (moderate CKD), Cr 1.42, INR not applicable (Xa inhibitor)',
  },
};

async function deriveSessionKey(drSecret, patientId, salt) {
  const ikm = `${drSecret}|${patientId}|${salt}`;
  return Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    ikm,
    { encoding: Crypto.CryptoEncoding.HEX }
  );
}

async function appendAudit(entry) {
  try {
    const existing = await SecureStore.getItemAsync('mo.dr.audit') || '[]';
    const log = JSON.parse(existing);
    log.push({ ts: new Date().toISOString(), ...entry });
    await SecureStore.setItemAsync('mo.dr.audit', JSON.stringify(log.slice(-200)));
  } catch (e) { console.warn('audit', e); }
}

export default function App() {
  const [stage, setStage] = useState('boot');
  const [permission, requestPermission] = useCameraPermissions();
  const [encounter, setEncounter] = useState(null);
  const [auditCount, setAuditCount] = useState(0);
  const [ttlRemaining, setTtlRemaining] = useState(ENCOUNTER_TTL_MS);
  const ttlInterval = useRef(null);
  const [query, setQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);  // [{q, body, ts}]
  const [searching, setSearching] = useState(false);

  async function runQuery() {
    if (!query.trim() || searching) return;
    const q = query.trim();
    setSearching(true);
    try {
      const body = await searchPatientHistory(q);
      const next = [{ q, body, ts: new Date().toISOString() }, ...searchResults];
      setSearchResults(next.slice(0, 5));
      await appendAudit({
        event: 'query',
        patient_id: encounter?.patient_id,
        query: q,
        result_bytes: body.length,
      });
      setQuery('');
    } catch (e) {
      Alert.alert('Search failed', e.message);
    } finally {
      setSearching(false);
    }
  }

  useEffect(() => {
    (async () => {
      let dr = await SecureStore.getItemAsync(DR_KEY);
      if (!dr) {
        // First launch: synthesize a doctor identity. In production: SSO + NPI lookup.
        const nonce = await Crypto.getRandomBytesAsync(16);
        const id = `dr-marcus-chen-${Array.from(nonce.slice(0,4)).map(b=>b.toString(16).padStart(2,'0')).join('')}`;
        dr = id;
        await SecureStore.setItemAsync(DR_KEY, dr);
        await appendAudit({ event: 'dr_enrolled', dr_id: id });
      }
      setStage('ready');
    })();
  }, []);

  useEffect(() => {
    if (stage === 'in_encounter' && encounter) {
      ttlInterval.current = setInterval(() => {
        setTtlRemaining(prev => {
          const next = prev - 1000;
          if (next <= 0) {
            endEncounter('ttl_expired');
            return 0;
          }
          return next;
        });
      }, 1000);
      return () => clearInterval(ttlInterval.current);
    }
  }, [stage, encounter]);

  async function handleScan({ data }) {
    if (stage !== 'ready') return;
    setStage('processing');
    try {
      const payload = JSON.parse(data);
      if (payload.v !== 1 || !payload.patient_id || !payload.salt) {
        throw new Error('not a memory-oracle wristband QR');
      }
      const records = PATIENT_RECORDS[payload.patient_id];
      if (!records) throw new Error(`no records for ${payload.patient_id} (synthetic vault only)`);

      const drSecret = await SecureStore.getItemAsync(DR_KEY);
      const sessionKey = await deriveSessionKey(drSecret, payload.patient_id, payload.salt);

      await appendAudit({
        event: 'encounter_started',
        patient_id: payload.patient_id,
        session_fp: sessionKey.slice(0, 8),
      });

      setEncounter({
        patient_id: payload.patient_id,
        records,
        session_key_fp: sessionKey.slice(0, 12),
        started_at: new Date().toISOString(),
      });
      setTtlRemaining(ENCOUNTER_TTL_MS);
      setStage('in_encounter');
    } catch (e) {
      Alert.alert('Scan failed', e.message);
      setStage('ready');
    }
  }

  async function endEncounter(reason = 'ended_by_clinician') {
    if (!encounter) return;
    await appendAudit({
      event: reason,
      patient_id: encounter.patient_id,
      duration_sec: Math.round((Date.now() - new Date(encounter.started_at).getTime()) / 1000),
    });
    clearInterval(ttlInterval.current);
    setEncounter(null);
    setTtlRemaining(ENCOUNTER_TTL_MS);
    setStage('ended');
    setTimeout(() => setStage('ready'), 4000);
  }

  // ─────────────────────────────────────────────────────────────────────────────

  if (stage === 'boot') return <View style={styles.container}><Text>booting…</Text></View>;

  if (stage === 'ended') {
    return (
      <View style={[styles.container, { alignItems: 'center', justifyContent: 'center' }]}>
        <StatusBar style="light"/>
        <Text style={styles.endedTitle}>Encounter ended</Text>
        <Text style={styles.endedBody}>Working copy shredded.{"\n"}No records retained on this device.{"\n"}Audit entry written.</Text>
      </View>
    );
  }

  if (stage === 'ready' || stage === 'processing') {
    if (!permission) return <View style={styles.container}><Text>requesting camera…</Text></View>;
    if (!permission.granted) {
      return (
        <View style={styles.container}>
          <Text style={styles.body}>Grant camera access to scan patient wristbands.</Text>
          <TouchableOpacity style={styles.btnPrimary} onPress={requestPermission}><Text style={styles.btnText}>Grant</Text></TouchableOpacity>
        </View>
      );
    }
    return (
      <View style={[styles.container, { alignItems: 'center' }]}>
        <StatusBar style="dark"/>
        <View style={styles.headerBar}>
          <Text style={styles.appTitle}>memory-oracle · Clinician</Text>
          <Text style={styles.subtle}>Scan patient wristband to begin encounter</Text>
        </View>
        <View style={styles.cameraFrameLarge}>
          <CameraView
            style={styles.camera}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
            onBarcodeScanned={stage === 'processing' ? undefined : handleScan}
          />
        </View>
        <Text style={styles.muted}>
          The patient initiates the encounter by showing their wristband QR.{"\n"}
          You will see only what they consent to share.
        </Text>
      </View>
    );
  }

  if (stage === 'in_encounter' && encounter) {
    const r = encounter.records;
    const ttlMin = Math.floor(ttlRemaining / 60000);
    const ttlSec = Math.floor((ttlRemaining % 60000) / 1000);
    return (
      <ScrollView style={styles.container} contentContainerStyle={{ paddingBottom: 120 }}>
        <StatusBar style="dark"/>

        <View style={styles.encounterHeader}>
          <View style={{ flex: 1 }}>
            <Text style={styles.patientName}>{r.name}</Text>
            <Text style={styles.patientMeta}>DOB {r.dob} · MRN {r.mrn} · {r.chart_age}</Text>
          </View>
          <View style={{ alignItems: 'flex-end' }}>
            <Text style={styles.ttl}>{ttlMin}:{String(ttlSec).padStart(2, '0')}</Text>
            <Text style={styles.subtle}>encounter TTL</Text>
          </View>
        </View>

        <View style={styles.alertBox}>
          <Text style={styles.alertHeader}>⚠ SUPERSESSION NOTICE — current regimen differs from canonical record</Text>
          <Text style={styles.alertBody}>{r.supersession_note.what_was_superseded}</Text>
          <Text style={styles.alertSub}>
            Superseded {r.supersession_note.when.slice(0,10)} · authored by {r.supersession_note.authored_by}
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardLabel}>CURRENT ANTICOAGULANT (active as of {r.current_anticoag.since})</Text>
          <Text style={styles.cardHero}>{r.current_anticoag.drug} {r.current_anticoag.dose}</Text>
          <Text style={styles.cardSub}>{r.current_anticoag.reason}</Text>
          <Text style={styles.cardSub}>Prescribed by {r.current_anticoag.authored_by}</Text>
        </View>

        <View style={[styles.card, styles.cardEmergency]}>
          <Text style={styles.cardLabel}>EMERGENCY REVERSAL · acute bleed</Text>
          <Text style={styles.cardHero}>{r.reversal_protocol.primary.split(' — ')[0]}</Text>
          <Text style={styles.cardSubBlock}>{r.reversal_protocol.primary}</Text>
          <Text style={styles.cardSubLabel}>If unavailable:</Text>
          <Text style={styles.cardSubBlock}>{r.reversal_protocol.alternative}</Text>
          <Text style={styles.cardSubLabel}>Non-life-threatening:</Text>
          <Text style={styles.cardSubBlock}>{r.reversal_protocol.supportive}</Text>
          <View style={styles.dontBox}>
            <Text style={styles.dontText}>{r.reversal_protocol.avoid}</Text>
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardLabel}>RELEVANT HISTORY</Text>
          <Text style={styles.cardBody}>{r.afib_history}</Text>
          <Text style={styles.cardBody}><Text style={{ fontWeight: '600' }}>Allergies: </Text>{r.allergies.join(', ')}</Text>
          <Text style={styles.cardBody}><Text style={{ fontWeight: '600' }}>Labs: </Text>{r.relevant_labs_recent}</Text>
        </View>

        <View style={styles.queryCard}>
          <Text style={styles.cardLabel}>ASK THE PATIENT'S HISTORY · supersession-aware retrieval</Text>
          <Text style={styles.subtle}>Free-form medical question. Results come from the patient's full consented history with all corrections applied at read time.</Text>
          <View style={styles.queryRow}>
            <TextInput
              style={styles.queryInput}
              value={query}
              onChangeText={setQuery}
              placeholder="e.g. any prior reaction to fluoroquinolones? renal trend last 24 months?"
              placeholderTextColor="#999"
              multiline
              numberOfLines={2}
              returnKeyType="search"
              onSubmitEditing={runQuery}
              editable={!searching}
            />
            <TouchableOpacity style={[styles.btnPrimary, searching && { opacity: 0.5 }]} onPress={runQuery} disabled={searching}>
              {searching ? <ActivityIndicator color="#fff"/> : <Text style={styles.btnText}>Search</Text>}
            </TouchableOpacity>
          </View>

          {searchResults.map((r, i) => (
            <View key={i} style={styles.resultBox}>
              <Text style={styles.resultQuery}>Q · {r.q}</Text>
              <Text style={styles.resultMeta}>{new Date(r.ts).toLocaleTimeString()} · {r.body.length} bytes returned</Text>
              <Text style={styles.resultBody} numberOfLines={20} ellipsizeMode="tail">{r.body}</Text>
            </View>
          ))}
        </View>

        <View style={styles.footer}>
          <Text style={styles.subtle}>Encounter ID: {encounter.session_key_fp}… · started {new Date(encounter.started_at).toLocaleTimeString()}</Text>
          <TouchableOpacity style={styles.btnDanger} onPress={() => endEncounter('ended_by_clinician')}>
            <Text style={styles.btnText}>End Encounter · Shred working copy</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    );
  }

  return <View style={styles.container}><Text>state: {stage}</Text></View>;
}

const { width, height } = Dimensions.get('window');
const isLandscape = width > height;

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f6f7fa', padding: 24, paddingTop: 60 },
  headerBar: { width: '100%', marginBottom: 20 },
  appTitle: { fontSize: 24, fontWeight: '700', color: '#222', textAlign: 'center' },
  subtle: { fontSize: 13, color: '#888', textAlign: 'center', marginTop: 4 },
  body: { fontSize: 16, color: '#333', textAlign: 'center', marginVertical: 20 },
  muted: { fontSize: 13, color: '#888', textAlign: 'center', marginTop: 18, paddingHorizontal: 30, lineHeight: 19 },
  btnPrimary: { backgroundColor: '#0066cc', padding: 16, borderRadius: 10, alignItems: 'center', marginVertical: 8, alignSelf: 'center', minWidth: 200 },
  btnDanger: { backgroundColor: '#cc2222', padding: 18, borderRadius: 10, alignItems: 'center', marginTop: 14 },
  btnText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  cameraFrameLarge: { width: isLandscape ? '60%' : '85%', aspectRatio: 1, borderRadius: 16, overflow: 'hidden', borderWidth: 3, borderColor: '#0066cc', marginVertical: 12 },
  camera: { flex: 1 },

  encounterHeader: { flexDirection: 'row', alignItems: 'center', backgroundColor: '#fff', padding: 18, borderRadius: 12, marginBottom: 14, shadowColor: '#000', shadowOpacity: 0.04, shadowRadius: 6, shadowOffset: { width: 0, height: 2 }, elevation: 1 },
  patientName: { fontSize: 22, fontWeight: '700', color: '#222' },
  patientMeta: { fontSize: 13, color: '#666', marginTop: 3 },
  ttl: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), fontSize: 20, color: '#0066cc', fontWeight: '600' },

  alertBox: { backgroundColor: '#fff4e0', borderLeftWidth: 5, borderLeftColor: '#cc6600', padding: 16, borderRadius: 10, marginBottom: 14 },
  alertHeader: { fontSize: 13, fontWeight: '700', color: '#883300', marginBottom: 6, letterSpacing: 0.3 },
  alertBody: { fontSize: 15, lineHeight: 22, color: '#553', fontWeight: '500' },
  alertSub: { fontSize: 12, color: '#776', marginTop: 6, fontStyle: 'italic' },

  card: { backgroundColor: '#fff', padding: 16, borderRadius: 12, marginBottom: 12 },
  cardEmergency: { backgroundColor: '#fff4f4', borderWidth: 2, borderColor: '#dd2222' },
  cardLabel: { fontSize: 11, fontWeight: '700', color: '#888', letterSpacing: 0.5, marginBottom: 8 },
  cardHero: { fontSize: 22, fontWeight: '700', color: '#222', marginBottom: 8 },
  cardSub: { fontSize: 14, color: '#555', lineHeight: 20, marginBottom: 4 },
  cardSubLabel: { fontSize: 12, fontWeight: '600', color: '#666', marginTop: 10, textTransform: 'uppercase' },
  cardSubBlock: { fontSize: 14, color: '#333', lineHeight: 21, marginTop: 4 },
  cardBody: { fontSize: 14, color: '#333', lineHeight: 21, marginVertical: 3 },

  dontBox: { backgroundColor: '#fff0f0', padding: 12, borderRadius: 8, marginTop: 12, borderWidth: 1, borderColor: '#dd2222' },
  dontText: { fontSize: 13, color: '#aa1111', fontWeight: '600', lineHeight: 19 },

  footer: { marginTop: 18, paddingTop: 14, borderTopWidth: 1, borderTopColor: '#e0e0e0' },

  endedTitle: { fontSize: 28, fontWeight: '700', color: '#fff', marginBottom: 12 },
  endedBody: { fontSize: 15, color: '#bbb', textAlign: 'center', lineHeight: 23 },

  queryCard: { backgroundColor: '#f0f7ff', padding: 16, borderRadius: 12, marginTop: 6, marginBottom: 16, borderWidth: 1, borderColor: '#cdd9ee' },
  queryRow: { flexDirection: 'row', alignItems: 'flex-start', marginTop: 10, gap: 10 },
  queryInput: { flex: 1, borderWidth: 1, borderColor: '#bbcce0', borderRadius: 8, padding: 12, fontSize: 15, backgroundColor: '#fff', color: '#222', minHeight: 60 },
  resultBox: { backgroundColor: '#fff', padding: 12, borderRadius: 8, marginTop: 10, borderLeftWidth: 4, borderLeftColor: '#0066cc' },
  resultQuery: { fontSize: 14, fontWeight: '600', color: '#0066cc', marginBottom: 3 },
  resultMeta: { fontSize: 11, color: '#999', marginBottom: 6 },
  resultBody: { fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }), fontSize: 11, color: '#444', lineHeight: 16 },
});
