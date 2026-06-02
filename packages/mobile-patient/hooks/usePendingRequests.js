// Foreground-only poller for pending EncounterRequests.
// Polls every 5s when the app is active; pauses when backgrounded.
// Returns: { requests, loading, error, relayReachable, refetch }.

import { useEffect, useRef, useState, useCallback } from 'react';
import { AppState } from 'react-native';
import { fetchPendingRequests, pingRelay } from '../lib/relay.js';

const POLL_INTERVAL_MS = 5000;

export function usePendingRequests(patientRecipient) {
  const [requests, setRequests] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [relayReachable, setRelayReachable] = useState(null);
  const abortRef = useRef(null);
  const timerRef = useRef(null);

  const fetchOnce = useCallback(async () => {
    if (!patientRecipient) return;
    if (abortRef.current) abortRef.current.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setLoading(true);
    try {
      const r = await fetchPendingRequests(patientRecipient, { signal: controller.signal });
      setRequests(r);
      setError(null);
      setRelayReachable(true);
    } catch (e) {
      if (e.name === 'AbortError') return;
      setError(e.message ?? String(e));
      setRelayReachable(false);
    } finally {
      setLoading(false);
    }
  }, [patientRecipient]);

  useEffect(() => {
    if (!patientRecipient) return;

    let mounted = true;

    const startPolling = () => {
      stopPolling();
      fetchOnce();
      timerRef.current = setInterval(() => {
        if (mounted) fetchOnce();
      }, POLL_INTERVAL_MS);
    };
    const stopPolling = () => {
      if (timerRef.current) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }
      if (abortRef.current) {
        abortRef.current.abort();
        abortRef.current = null;
      }
    };

    // Initial reachability check (one-shot) so the UI can show a hint.
    pingRelay().then(ok => mounted && setRelayReachable(ok));

    startPolling();

    const onAppStateChange = (nextState) => {
      if (nextState === 'active') startPolling();
      else stopPolling();
    };
    const sub = AppState.addEventListener('change', onAppStateChange);

    return () => {
      mounted = false;
      stopPolling();
      sub.remove();
    };
  }, [patientRecipient, fetchOnce]);

  return { requests, loading, error, relayReachable, refetch: fetchOnce };
}
