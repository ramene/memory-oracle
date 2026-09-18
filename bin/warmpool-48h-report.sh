#!/usr/bin/env bash
# warmpool-48h-report.sh — DETERMINISTIC provable warmpool activity for the nightly sprint retrospective.
# LAW (operator 2026-09-18): embed this block VERBATIM in every retro; never hand-type the numbers.
# Reads blvck-pi warmer.db as the sandboxed warmpool user. Safe/read-only.
echo "### warmpool — provable 48h activity  ($(date -u +%FT%TZ))"
ssh -o ConnectTimeout=12 -o BatchMode=yes blvck-pi 'bash -s' <<'REMOTE' 2>/dev/null | grep -v -iE 'rfkill|raspi-config|Wi-Fi is currently'
DB=/mnt/substrate/warmpool/state/warmer.db
echo "-- sends per day (last 48h) --"
sudo -n -u warmpool sqlite3 -header -column "$DB" "select substr(sent_at,1,10) day, count(*) sent, substr(max(sent_at),12,9) last_send from sends where status='sent' and sent_at>=datetime('now','-48 hours') group by day order by day desc;"
echo "-- totals + domains --"
sudo -n -u warmpool sqlite3 "$DB" "select 'total_sent_alltime='||count(*) from sends where status='sent';"
sudo -n -u warmpool sqlite3 -header -column "$DB" "select domain, status, warmup_started_on start, ramp_cap cap, coalesce(graduated_at,'-') graduated from domains;"
echo -n "warmpool-warmer.service="; systemctl is-active warmpool-warmer.service 2>/dev/null
echo -n "warmpool-score.timer=";   systemctl is-active warmpool-score.timer 2>/dev/null
REMOTE
