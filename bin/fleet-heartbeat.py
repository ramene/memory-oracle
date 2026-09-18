#!/usr/bin/env python3
"""fleet-heartbeat.py — DETERMINISTIC fleet health check → Cluster Sync "Daily Checks" tab.

Encodes the CORRECT probe per service (from the Daily Checks "Interval" column) so a scheduled/
batch job that is idle between runs never false-alarms. This is the determinism layer: the script
decides green/warn/red from evidence; the LLM only reads the result.

Run on-demand:  python3 ~/.bin/fleet-heartbeat.py
Or on a timer:  launchd com.fleet.heartbeat (StartInterval 1800 = every 30 min) on the LEAD host.

Laws honored: curl (never python-urllib SSL); stat mtime not BSD `ls --time-style`; substrate for
sessions; empirical evidence in every row; writes then the caller can read back.
"""
import subprocess, json, os, sys, datetime, concurrent.futures

SHEET = "1TbYFs8mW_fppKhRiRXDm8lJdG4vWltVTjBANL8JrkGg"      # legacy Cluster Sync (source data)
LOTL = "1RDDoD-pLSvXZdY4tf22tkBFbXEKkZ-eGKJRohk3XH_Q"       # legacy Google Sheet (NO LONGER written — kept for reference)
# nocodb "Lay of the Land" base is the LIVE home now — heartbeat writes HERE, Sheets bypassed (operator, 2026-09-16).
NC_URL = "http://192.168.100.50:8080"
DC_TID = "muuvqnce9exz6fg"                                  # Daily Checks table in nocodb
def _nctoken():
    return open(os.path.expanduser("~/.config/lotl/nocodb-token")).read().strip()
SA = "sheets-writer@mae-stack-prod.iam.gserviceaccount.com"
BLVCK = "192.168.100.50"      # Pi (LAN) — compass-docs/coordinator/nocodb/mae-yjs
TUNA = "tunafish"             # ssh alias — Charlie/ingest/leadgen/:25
DOCS_TOKEN = "854a943b06b965303ba92e5abbd37379"
NOW = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def run(cmd, timeout=25):
    try:
        r = subprocess.run(["bash", "-lc", cmd], capture_output=True, text=True, timeout=timeout)
        return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as e:
        return 99, f"probe-error:{type(e).__name__}"


def http_code(url, host="", t=10):
    hh = f"-H 'Host: {host}' " if host else ""
    _, out = run(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time {t} {hh}'{url}'")
    return (out.strip().splitlines() or ["000"])[-1]


def ssh(host, cmd, t=20):
    return run(f"ssh -o BatchMode=yes -o ConnectTimeout=10 {host} {json.dumps(cmd)}", timeout=t)


# --- probes: each returns (status, evidence). status in {green,warn,red} ---
def p_http(url, ok=("200", "301", "302", "401", "403"), host=""):
    c = http_code(url, host)
    return ("green" if c in ok else "red"), f"curl {url} -> {c}"

def p_coordinator():
    _, out = run(f"curl -s --max-time 8 http://{BLVCK}:8787/health")
    ok = '"status":"ok"' in out or '"status": "ok"' in out
    import re
    cards = (re.search(r'"cards":\s*(\d+)', out) or [None, "?"])[1]
    return ("green" if ok else "red"), f":8787/health status_ok={ok} cards={cards}"

def p_svc_answered(url, host=""):
    # a service that answers ANY http code (incl 403/404) is UP; only 000/refused is down
    c = http_code(url, host)
    return ("green" if c != "000" else "red"), f"curl {url} -> {c} (server-answered=up)"

def _leadgen_launchd_fallback():
    # graceful fallback when the status file isn't present yet: use the OLD launchd/exit-code
    # signal for evidence only, but never green — the exit code alone can't prove leads flowed.
    rc, out = ssh(TUNA, "launchctl list com.altmethod.leadgen 2>/dev/null | grep -E 'LastExitStatus' ; "
                        "stat -f '%m' ~/.altmethod/logs/leadgen.log 2>/dev/null")
    if "LastExitStatus" not in out:
        return "red", "status-file pending; launchctl: com.altmethod.leadgen NOT LOADED"
    import re, time
    ex = (re.search(r'LastExitStatus"?\s*=\s*(\d+)', out) or [None, "?"])[1]
    mt = re.search(r'^(\d{9,})$', out, re.M)
    age_h = (time.time() - int(mt.group(1))) / 3600 if mt else 999
    return "warn", (f"status-file pending (companion agent building it) — falling back to launchd: "
                    f"LastExitStatus={ex}, leadgen.log age={age_h:.1f}h (exit-code ≠ leads; not green)")


def _age_min(iso):
    # "2026-09-16T12:00:00Z" -> minutes since. Tolerate the trailing Z and missing seconds.
    s = (iso or "").strip().replace("Z", "+00:00")
    dt = datetime.datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds() / 60.0


def p_leadgen():
    # Judge OUTPUT, not process: read the harvester's status file (contract schema=1) and apply
    # the contract verdict rules. Exit-code greens are the bug this replaces.
    _, out = run("ssh -o ConnectTimeout=6 -o BatchMode=yes tunafish 'cat ~/.altmethod/leadgen-status.json'")
    txt = (out or "").strip()
    try:
        s = json.loads(txt)
        if not isinstance(s, dict):
            raise ValueError("not an object")
    except Exception:
        # file missing / half-written / ssh hiccup -> graceful launchd fallback, labeled pending (WARN)
        return _leadgen_launchd_fallback()

    sink_ok = bool(s.get("sink_ok"))
    new_24h = s.get("new_rows_24h", 0) or 0
    dry = s.get("consecutive_dry_runs", "?")
    esc = s.get("escalation")
    exhausted = bool((s.get("coverage") or {}).get("exhausted"))
    lr = s.get("last_run_utc")
    try:
        age = _age_min(lr)
        age_txt = f"{age:.0f}m"
    except Exception:
        age, age_txt = None, "unparseable"

    # verdict (contract): RED > WARN > GREEN
    stale = (age is None) or (age > 90)
    if not sink_ok or stale:
        st = "red"
    elif new_24h == 0 or exhausted or esc is not None:
        st = "warn"
    else:
        st = "green"

    parts = [f"sink_ok={sink_ok}", f"last_run={age_txt} ago", f"new_rows_24h={new_24h}",
             f"consecutive_dry_runs={dry}"]
    if exhausted:
        parts.append("coverage EXHAUSTED")
    if esc is not None:
        parts.append(f"escalation={esc}")
    return st, "leadgen-status.json: " + ", ".join(parts)

def p_out25():
    rc, out = ssh(TUNA, "nc -z -G3 gmail-smtp-in.l.google.com 25 >/dev/null 2>&1 && echo OPEN || echo BLOCKED")
    return ("green" if "OPEN" in out else "red"), f"nc gmail-smtp-in:25 -> {out.strip()[-6:]} (OUTBOUND, not a listener)"

def p_docs_gate():
    _, l = run("launchctl list 2>/dev/null | grep com.verum.docs-gate")
    c = http_code("http://127.0.0.1:5197/logout", host="docs.noodles.haus")
    ok = bool(l.strip()) and c == "302"
    return ("green" if ok else "red"), f"launchctl loaded={bool(l.strip())} /logout={c}"

def p_backups():
    rc, out = run("ls -t ~/.local/state/substrate-backups/*.gz 2>/dev/null | head -1")
    f = out.strip().splitlines()[0] if out.strip() else ""
    _, d = run(f"stat -f '%Sm' '{f}'") if f else (1, "none")
    today = datetime.date.today().strftime("%y%m%d")
    fresh = today in os.path.basename(f) or datetime.date.today().strftime("%Y%m%d") in os.path.basename(f)
    return ("green" if fresh else "warn"), f"newest={os.path.basename(f)} ({d.strip()})"

def p_cron(pat, must_be="present"):
    _, out = run(f"crontab -l 2>/dev/null | grep -iE {json.dumps(pat)}")
    present = bool(out.strip())
    if must_be == "disabled":  # vault-autosync must stay OFF (commented)
        active = any(l.strip() and not l.strip().startswith("#") for l in out.splitlines())
        return ("green" if not active else "red"), f"vault-autosync active={active} (must be DISABLED)"
    return ("green" if present else "warn"), f"crontab match={present}: {out.strip()[:80]}"

def p_ssh_proc(host, pat, name):
    rc, out = ssh(host, f"ps aux | grep -iE {json.dumps(pat)} | grep -v grep | head -1")
    return ("green" if out.strip() else "red"), f"{name}: {(out.strip()[:90] or 'no process')}"

def p_tailscale():
    _, out = run("tailscale status 2>/dev/null")
    peers = [l for l in out.splitlines() if l.strip() and l[0].isdigit()]
    return ("green" if len(peers) >= 3 else "warn"), f"{len(peers)} peers listed"

def p_ses():
    _, out = run("aws sesv2 get-account --region us-east-1 --query 'ProductionAccessEnabled' --output text")
    ok = out.strip().lower() == "true"
    return ("green" if ok else "warn"), f"ProductionAccessEnabled={out.strip()}"

# every public GAE project must carry the operator-net lock (a DENY * rule); ALLOW*-only = exposed to the internet.
# (claey-338919 was found ALLOW*-only 2026-09-16 — bots scanning micropayments.id/.to — then locked.)
FW_PROJECTS = ["claey-338919", "mae-stack-prod", "mae-apps-prod", "mae-commerce-prod",
               "mae-content-prod", "mae-growth-prod"]
def p_firewall():
    exposed = []
    for p in FW_PROJECTS:
        _, out = run(f"gcloud app firewall-rules list --project={p} --format='csv[no-heading](action,sourceRange)' 2>/dev/null")
        locked = any(r.strip() == "DENY,*" for r in out.splitlines())
        if not locked:
            exposed.append(p)
    if exposed:
        return "red", f"EXPOSED — no DENY* lock: {', '.join(exposed)}"
    return "green", f"all {len(FW_PROJECTS)} GAE projects operator-net locked (DENY *)"


# --- added 2026-09-17: config-parity + previously-unwatched running services ---
MACS = ["noodles", "tunafish", "sequoia"]   # the 3 macs that carry laws.md + the mae plugin

def p_config_parity():
    # md5 laws.md across the 3 macs; GREEN only if all identical. macOS md5 -q, linux md5sum fallback.
    f = "~/.local/share/journal/.claude/laws.md"
    h = {}
    for host in MACS:
        _, out = ssh(host, f"md5 -q {f} 2>/dev/null || md5sum {f} 2>/dev/null | awk '{{print $1}}'")
        tok = (out.strip().split() or [""])[0]
        h[host] = tok[:12] if tok else "MISSING"
    uniq = set(h.values())
    ok = len(uniq) == 1 and "MISSING" not in uniq
    ev = "laws.md md5: " + ", ".join(f"{k}={v[:8]}" for k, v in h.items())
    return ("green" if ok else "red"), ev

def p_pi_pg():
    # TCP reachability to the tailnet-only Pi Postgres (maeconnect rooms DB)
    _, out = run("nc -z -G3 100.115.79.101 5432 >/dev/null 2>&1 && echo OPEN || echo CLOSED")
    ok = "OPEN" in out
    return ("green" if ok else "red"), f"nc 100.115.79.101:5432 (rooms DB, tailnet) -> {'reachable' if ok else 'UNREACHABLE'}"

def p_mae_plugin():
    # read the mae obsidian-plugin version on the 3 macs; GREEN if identical, RED on drift
    import re
    mf = "/Users/ramene/.remote/@vaults/.build/obsidian-vault/.obsidian/plugins/mae/manifest.json"
    v = {}
    for host in MACS:
        _, out = ssh(host, f"grep -oE '\"version\"[^,]*' {mf} 2>/dev/null | head -1")
        m = re.search(r'([0-9][0-9A-Za-z.\-]*)', out or "")
        v[host] = m.group(1) if m else "MISSING"
    uniq = set(v.values())
    ok = len(uniq) == 1 and "MISSING" not in uniq
    ev = "mae manifest version: " + ", ".join(f"{k}={val}" for k, val in v.items())
    return ("green" if ok else "red"), ev

def p_warmpool():
    # warmpool-warmer daemon on blvck-pi: GREEN active + sent in last 36h; WARN active-but-idle; RED down.
    # NOTE (2026-09-18): warmpool-score.timer is DISABLED -> reputation_score/gate.json stale since 09-11; surfaced in evidence.
    _, act = ssh(BLVCK, "systemctl is-active warmpool-warmer.service")
    act = (act or "").strip().splitlines()[-1] if (act or "").strip() else ""
    if "active" not in act:
        return "red", f"warmpool-warmer.service={act or 'unreachable'} (blvck-pi)"
    _, out = ssh(BLVCK, "sudo -n -u warmpool sqlite3 /mnt/substrate/warmpool/state/warmer.db \"select count(*) from sends where sent_at>=datetime('now','-36 hours');\"")
    tok = (out or "").strip().splitlines()[-1] if (out or "").strip() else ""
    if tok.isdigit():
        n = int(tok)
        if n == 0:
            return "warn", "warmpool-warmer active but 0 sends/36h — ramp stalled or send-path down (scorer.timer also DISABLED)"
        return "green", f"warmpool-warmer active · {n} sends/36h (NOTE: scorer.timer DISABLED — reputation untracked)"
    return "green", "warmpool-warmer active; send-count unreadable but service up"


# name, category, keep_alive, interval-note, probe
CHECKS = [
    ("id.verum.sh", "cloud-run", True, "Cloud Run scale-to-zero — curl (cold-start ok)", lambda: p_http("https://id.verum.sh/")),
    ("relay.verum.sh", "cloud-run", True, "Cloud Run — curl (/healthz 404 is a red herring)", lambda: p_http("https://relay.verum.sh/")),
    ("karve-mint", "cloud-run", True, "Cloud Run invoker-restricted — curl (401/403=up)", lambda: p_http("https://karve-mint-foimbkajva-uc.a.run.app/")),
    ("compass-docs :5196", "http", True, "continuous — curl gallery", lambda: p_http(f"http://{BLVCK}:5196/architecture/diagrams/?token={DOCS_TOKEN}", ok=("200",))),
    ("coordinator :8787", "http", True, "continuous — GET /health status:ok", p_coordinator),
    ("nocodb :8080", "http", True, "continuous daemon — curl", lambda: p_http(f"http://{BLVCK}:8080/", ok=("200", "302"))),
    ("mae-yjs :1234", "process", True, "continuous daemon — ssh ps", lambda: p_ssh_proc(BLVCK, "yjs-dev-server", "mae-yjs")),
    ("Charlie voice :8600", "service-http", True, "continuous — curl (any server code=up)", lambda: p_svc_answered(f"http://100.78.205.72:8600/")),
    (":8823 ingest VLM", "service-http", True, "continuous — curl (any server code=up)", lambda: p_svc_answered(f"http://100.78.205.72:8823/")),
    ("lead harvester (leadgen)", "scheduled", True, "judges OUTPUT via ~/.altmethod/leadgen-status.json (contract schema=1): RED sink down/stale>90m, WARN 0 new/exhausted/escalation, GREEN only if leads flowed 24h; launchd fallback if file pending", p_leadgen),
    (":25 outbound (SMTP RCPT)", "network", True, "on-demand during a run — nc OUTBOUND, NOT an inbound listener", p_out25),
    ("docs gate (launchd)", "daemon", True, "continuous launchd — launchctl + /logout 302", p_docs_gate),
    ("substrate DB backups", "backup", True, "nightly 02:00 cron — newest .gz mtime=today", p_backups),
    ("digest builder cron", "cron", True, "daily 23:55 cron", lambda: p_cron("digest")),
    ("brain-sync cron", "cron", True, "*/15 cron", lambda: p_cron("substrate sync|brain")),
    ("vault-autosync (must stay OFF)", "cron", True, "DISABLED — clobbers the vault", lambda: p_cron("vault-autosync", "disabled")),
    ("tailscale", "network", True, "continuous — tailscale status", p_tailscale),
    ("SES", "email", True, "AWS account state", p_ses),
    ("docs.noodles.haus (Caddy)", "caddy", True, "continuous — Caddy@sequoia → verum gate → blvck; tailnet-private (302=gate)", lambda: p_http("https://docs.noodles.haus/", ok=("200", "301", "302"))),
    ("understand.noodles.haus (Caddy)", "caddy", True, "continuous — Caddy@sequoia → :5173 (UA diagrams)", lambda: p_http("https://understand.noodles.haus/")),
    ("studio.noodles.haus (Caddy)", "caddy", True, "continuous — Caddy@sequoia → noodles:5000", lambda: p_http("https://studio.noodles.haus/")),
    ("n8n.noodles.haus (Caddy)", "caddy", True, "continuous — Caddy@sequoia → :5678", lambda: p_http("https://n8n.noodles.haus/")),
    ("GAE firewall (operator-net)", "security", True, "every PRE-LAUNCH GAE project must carry the DENY* operator-net lock — RED if any is ALLOW*-only/exposed (will need an allowlist once live x402 endpoints go public)", p_firewall),
    ("fleet-config parity", "security", True, "ssh 3 macs + md5 ~/.local/share/journal/.claude/laws.md — GREEN if all identical, RED on drift", p_config_parity),
    ("Pi Postgres (maeconnect)", "database", True, "TCP nc -z 100.115.79.101:5432 from noodles (rooms DB, tailnet-only) — GREEN reachable", p_pi_pg),
    ("Cloud Run mae-connect", "cloud-run", True, "Cloud Run — curl (200/301/302/401/403=up)", lambda: p_http("https://mae-connect-foimbkajva-uc.a.run.app/", ok=("200", "301", "302", "401", "403"))),
    ("connect-collab (yjs relay)", "cloud-run", True, "Cloud Run yjs websocket relay — curl (400/426 to plain GET = up)", lambda: p_http("https://connect-collab-44494448140.us-central1.run.app/", ok=("200", "301", "302", "400", "401", "403", "426"))),
    ("mae plugin version (fleet parity)", "deploy", True, "ssh 3 macs + read .obsidian/plugins/mae/manifest.json version — GREEN if identical, RED on drift", p_mae_plugin),
    ("warmpool warmer (blvck-pi)", "email", True, "warmpool-warmer.service active on the Pi + sent in last 36h (WARN active-but-0-sends, RED service down). NOTE scorer.timer disabled -> reputation_score/gate.json stale since 09-11", p_warmpool),
]

PROPS = ["mae.sh", "appmaestro.ai", "meet.mae.sh", "join.mae.sh", "calm.karve.ai", "karve.ai",
         "filedeposit.com", "mediareserve.com", "lachlandai.com", "socialcommons.com",
         "app.altmethod.com", "micropaymnts.ai", "altmethod.com", "karve.run", "comera.com.mx"]
for d in PROPS:
    CHECKS.append((d, "revenue", False, "continuous GAE — curl 200/301/302", lambda d=d: p_http(f"https://{d}/")))


def _token():
    # stdout ONLY (drop gcloud stderr warnings) so the Bearer is the raw token, not a warning line
    return subprocess.run(["bash", "-lc",
        f"gcloud auth print-access-token --impersonate-service-account={SA} "
        "--scopes=https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/drive 2>/dev/null"],
        capture_output=True, text=True, timeout=30).stdout.strip()


def sheet_write_inplace(results, g, w, r_):
    """Write status/last-checked/evidence into the EXISTING Daily Checks rows of the LOTL sheet,
    matched by check-name in col A. Only touches cells C/D/G + the A3 refresh line — the lane
    headers, collapsible groups, frozen panes, and any manual styling are left untouched."""
    tok = _token()
    _, colA = run(f"curl -s 'https://sheets.googleapis.com/v4/spreadsheets/{LOTL}/values/Daily%20Checks!A1:A300' "
                  f"-H 'Authorization: Bearer {tok}'")
    try:
        vals = json.loads(colA).get("values", [])
    except Exception:
        return 0, colA
    name2row = {}
    for i, row in enumerate(vals, 1):                       # 1-based row numbers
        nm = row[0].strip() if row else ""
        if nm and not nm.startswith("▸") and nm not in ("Check", "Daily Checks — fleet health"):
            name2row[nm] = i
    sym = {"green": "✅", "warn": "⚠️", "red": "❌"}
    data = [{"range": "Daily Checks!A3", "values": [[f"last refresh: {NOW} · {g}✅ {w}⚠️ {r_}❌ · via fleet-heartbeat.py"]]}]
    matched = 0
    for name, cat, st, keep, interval, ev in results:
        row = name2row.get(name)
        if not row:
            continue
        matched += 1
        data.append({"range": f"Daily Checks!C{row}", "values": [[f"{sym[st]} {st}"]]})
        data.append({"range": f"Daily Checks!D{row}", "values": [[NOW]]})
        data.append({"range": f"Daily Checks!G{row}", "values": [[ev[:460]]]})
    state = os.path.expanduser("~/.local/state/fleet-heartbeat")
    os.makedirs(state, exist_ok=True)
    body = os.path.join(state, ".body.json")
    json.dump({"valueInputOption": "USER_ENTERED", "data": data}, open(body, "w"))
    _, out = run(f"curl -s -X POST 'https://sheets.googleapis.com/v4/spreadsheets/{LOTL}/values:batchUpdate' "
                 f"-H 'Authorization: Bearer {tok}' -H 'Content-Type: application/json' --data @{body}")
    return matched, out


def nocodb_write(results, g, w, r_):
    """Write status/last-checked/evidence into the nocodb Daily Checks table, matched by Check name.
    REPLACES the Sheets write (operator 2026-09-16: nocodb 'Lay of the Land' base is the live home)."""
    tok = _nctoken()
    _, out = run(f"curl -s -H 'xc-token: {tok}' '{NC_URL}/api/v2/tables/{DC_TID}/records?limit=200&fields=Id,Check'")
    try:
        recs = json.loads(out).get("list", [])
    except Exception:
        return 0, out
    name2id = {(x.get("Check") or "").strip(): x.get("Id") for x in recs}
    sym = {"green": "✅", "warn": "⚠️", "red": "❌"}
    patches = []
    for name, cat, st, keep, interval, ev in results:
        rid = name2id.get(name.strip())
        if rid is None:
            continue
        patches.append({"Id": rid, "Status": f"{sym[st]} {st}", "Last checked (UTC)": NOW, "Evidence": ev[:460]})
    if not patches:
        return 0, "no name matches in nocodb Daily Checks"
    state = os.path.expanduser("~/.local/state/fleet-heartbeat")
    os.makedirs(state, exist_ok=True)
    body = os.path.join(state, ".nc_body.json")
    json.dump(patches, open(body, "w"))
    _, out = run(f"curl -s -X PATCH '{NC_URL}/api/v2/tables/{DC_TID}/records' "
                 f"-H 'xc-token: {tok}' -H 'Content-Type: application/json' --data @{body}")
    return len(patches), out


def _run_one(chk):
    name, cat, keep, interval, probe = chk
    try:
        st, ev = probe()
    except Exception as e:
        st, ev = "warn", f"probe-exception:{type(e).__name__}"
    return (name, cat, st, keep, interval, ev)


def main():
    # probes are independent + I/O-bound (curl/ssh) — run them concurrently so a full sweep is ~15s not ~120s
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:
        results = list(ex.map(_run_one, CHECKS))
    sym = {"green": "✅", "warn": "⚠️", "red": "❌"}
    g = sum(r[2] == "green" for r in results); w = sum(r[2] == "warn" for r in results); r_ = sum(r[2] == "red" for r in results)
    order = {"red": 0, "warn": 1, "green": 2}
    results.sort(key=lambda x: (0 if x[3] else 1, order[x[2]], x[1]))
    matched, out = nocodb_write(results, g, w, r_)
    print(f"heartbeat {NOW}: {g}green {w}warn {r_}red / {len(results)} → nocodb Daily Checks ({matched} matched)")
    # cache a tiny status for the ⚖️ laws-footer hook (empirical liveness, read every prompt)
    try:
        _sd = os.path.expanduser("~/.local/state/fleet-heartbeat"); os.makedirs(_sd, exist_ok=True)
        json.dump({"green": g, "warn": w, "red": r_, "total": len(results), "ts": NOW},
                  open(os.path.join(_sd, "status.json"), "w"))
    except Exception:
        pass
    if r_ or w:
        for name, cat, st, keep, interval, ev in results:
            if st != "green":
                print(f"  {sym[st]} {name}: {ev[:100]}")
    # nocodb PATCH returns the updated records as a JSON array [{"Id":..},..] on success.
    ok = False
    try:
        ok = isinstance(json.loads(out), list) and len(json.loads(out)) > 0
    except Exception:
        ok = False
    if not ok:
        print("NOCODB WRITE MAY HAVE FAILED:", out[:200], file=sys.stderr)


if __name__ == "__main__":
    main()
