#!/bin/bash
# lmcanvas-divergence-audit.sh — flag lmcanvas-am-catalog checkout divergence across the
# cluster (canonical=sequoia, peer=tunafish) vs origin AND each other. Catches the
# disparate-source disease early (the same class the nightly-lie-audit caught for arch-notes).
BR="${LMCANVAS_BRANCH:-feat/lmcanvas-host-level-refactor-2026-06-30}"
LIES=0; declare -A H
for host in sequoia tunafish; do
  read -r head behind dirty < <(ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" \
    "cd ~/lmcanvas-am-catalog 2>/dev/null && git fetch -q origin 2>/dev/null; \
     echo \$(git rev-parse --short HEAD 2>/dev/null) \$(git rev-list --count HEAD..origin/$BR 2>/dev/null) \$(git status --porcelain 2>/dev/null|wc -l|tr -d ' ')" 2>/dev/null)
  H[$host]="$head"
  if [ -z "$head" ]; then echo "  ✗ LIE: $host lmcanvas checkout unreachable/missing"; LIES=$((LIES+1)); continue; fi
  [ "${behind:-0}" != "0" ] && { echo "  ✗ LIE: $host lmcanvas $behind commit(s) behind origin/$BR (head=$head)"; LIES=$((LIES+1)); }
  [ "${dirty:-0}" != "0" ] && { echo "  ⚠ WARN: $host lmcanvas has $dirty uncommitted file(s)"; }
done
[ -n "${H[sequoia]}" ] && [ -n "${H[tunafish]}" ] && [ "${H[sequoia]}" != "${H[tunafish]}" ] && \
  { echo "  ✗ LIE: sequoia(${H[sequoia]}) != tunafish(${H[tunafish]}) — checkouts diverged"; LIES=$((LIES+1)); }
[ "$LIES" = "0" ] && echo "  ✓ lmcanvas checkouts in parity (sequoia=${H[sequoia]} tunafish=${H[tunafish]})"
exit 0
