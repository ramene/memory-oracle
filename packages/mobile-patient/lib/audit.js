// Audit log helpers — SecureStore-backed, last-100 ring buffer.
// In production this would mirror to the memory-oracle audit endpoint
// for the HIPAA §164.526 trail; in 3c-iv we keep it on-device only.

import * as SecureStore from 'expo-secure-store';

const AUDIT_LOG_KEY = 'mo.patient.audit.log';

export async function appendAudit(entry) {
  try {
    const existing = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
    const log = existing ? JSON.parse(existing) : [];
    log.push({ ts: new Date().toISOString(), ...entry });
    const trimmed = log.slice(-100);
    await SecureStore.setItemAsync(AUDIT_LOG_KEY, JSON.stringify(trimmed));
    return trimmed;
  } catch (e) {
    console.warn('audit append failed', e);
    return [];
  }
}

export async function readAudit() {
  try {
    const existing = await SecureStore.getItemAsync(AUDIT_LOG_KEY);
    return existing ? JSON.parse(existing) : [];
  } catch (e) {
    console.warn('audit read failed', e);
    return [];
  }
}
