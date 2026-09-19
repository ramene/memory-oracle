#!/usr/bin/env bash
# ingest-share-mount.sh — mount the tunafish ingest scratch share at the SAME path locally.
# RUN ON EACH CLIENT (noodles, sequoia) WITH SUDO:  ! sudo ~/.bin/ingest-share-mount.sh
# Path-parity: mountpoint == server path, so mp4_path is identical on every host.
# Idempotent: remounts cleanly if already mounted.
set -euo pipefail
MP="/Users/ramene/ingest-scratch"
SRV="192.168.100.10:/Users/ramene/ingest-scratch"   # tunafish LAN IP (avoids name-resolution deps)

mkdir -p "$MP"
if mount | grep -q " on $MP "; then
  umount "$MP" 2>/dev/null || diskutil umount force "$MP" 2>/dev/null || true
fi
# The tunafish export does NOT require a reserved port (mapall=ramene, no resvport restriction),
# so noresvport mounts as the USER — NO SUDO. soft+timeo+retrans make a network flap return an
# ERROR instead of WEDGING the client mount (the recurring-wedge fix, 2026-09-18).
mount -t nfs -o noresvport,rw,nolocks,locallocks,soft,timeo=30,retrans=2 "$SRV" "$MP"

echo "=== mount ==="; mount | grep " on $MP " && echo "[ok] mounted $SRV -> $MP"
H="$(hostname -s)"
if touch "$MP/.reach-$H" 2>/dev/null; then echo "[ok] write test passed ($H)"; rm -f "$MP/.reach-$H"; else echo "[FAIL] cannot write to $MP"; exit 1; fi
