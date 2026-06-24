#!/usr/bin/env node
// mae-substrate-export — M3-α₁: package a substrate snapshot + signed manifest.
//
// α₁ scope (this file): collect tier-1 (memory bank) + tier-2 (current session
// JSONL + BM25 index), tar them, build the §3.F manifest, Ed25519-sign it with the
// operator's verum identity. ENCRYPTION IS DEFERRED TO α₂ (reuse M2 share.ts ECDH +
// ChaCha20). So the payload here is plaintext tar.gz; the manifest's recipient/
// ephemeral pubkey fields are populated only when --recipient is given (for α₂).
//
// Verifiable with Node stdlib alone (no vendor): the manifest signature is
//   crypto.verify(null, canonical(manifest), spkiPub, sig).
//
// Usage:
//   node mae-substrate-export.mjs --project <slug> --session <uuid> [--out <dir>]
//        [--recipient <x25519-pub-b64>] [--notes "..."] [--dry-run]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const HOME = os.homedir();
const args = parseArgs(process.argv.slice(2));
const slug = req(args.project, "--project");
const sessionId = req(args.session, "--session"); // α₁: validate against current session FIRST
const outDir = path.resolve(args.out || ".");
const dryRun = !!args["dry-run"];
const verumKeyPath = process.env.VERUM_IDENTITY_KEY || path.join(HOME, ".verum", "operator-ed25519.key");

const projDir = path.join(HOME, ".claude", "projects", slug);
const runtimeMem = path.join(HOME, ".claude", "projects", "_runtime", "memory");
const bm25 = path.join(HOME, ".local", "share", "journal", ".memory-index.db");
const EXCLUSION = ["**/.git/**", "**/.verum/**", "**/.credentials/**", "**/data.json"];

// ── identity ────────────────────────────────────────────────────────────────
const priv = crypto.createPrivateKey(fs.readFileSync(verumKeyPath));
const pub = crypto.createPublicKey(priv);
const edPubRawB64 = pub.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
const machineFp = crypto.createHash("sha256").update(os.hostname() + edPubRawB64).digest("hex");

// ── collect tier paths ────────────────────────────────────────────────────────
const tier1 = [];
const stagedAs = new Map(); // abs path -> relative path inside the payload
if (args.full) {
  // FULL ("whole brain"): every project's memory bank + all journal digests.
  const projectsRoot = path.join(HOME, ".claude", "projects");
  for (const proj of fs.readdirSync(projectsRoot)) {
    const pm = path.join(projectsRoot, proj, "memory");
    if (!fs.existsSync(pm)) continue;
    for (const f of fs.readdirSync(pm)) if (f.endsWith(".md")) {
      const abs = path.join(pm, f); tier1.push(abs); stagedAs.set(abs, path.join("projects", proj, "memory", f));
    }
  }
  const digestsRoot = process.env.JOURNAL_DIGESTS_ROOT || path.join(HOME, ".local", "share", "journal", "digests");
  if (fs.existsSync(digestsRoot)) for (const f of fs.readdirSync(digestsRoot)) if (f.endsWith(".md")) {
    const abs = path.join(digestsRoot, f); tier1.push(abs); stagedAs.set(abs, path.join("digests", f));
  }
} else {
  // single project: this project's memory + CLAUDE.md + recent _runtime rules
  const memDir = path.join(projDir, "memory");
  if (fs.existsSync(memDir)) for (const f of fs.readdirSync(memDir)) if (f.endsWith(".md")) { const a = path.join(memDir, f); tier1.push(a); stagedAs.set(a, path.join("memory", f)); }
  const projClaude = path.join(projDir, "CLAUDE.md");
  if (fs.existsSync(projClaude)) { tier1.push(projClaude); stagedAs.set(projClaude, "CLAUDE.md"); }
  if (fs.existsSync(runtimeMem)) {
    const cutoff = Date.now() - 14 * 864e5;
    for (const f of fs.readdirSync(runtimeMem))
      if (f.endsWith(".md") && fs.statSync(path.join(runtimeMem, f)).mtimeMs >= cutoff) { const a = path.join(runtimeMem, f); tier1.push(a); stagedAs.set(a, path.join("_runtime", f)); }
  }
}
const tier2 = [];
const sessJsonl = path.join(projDir, `${sessionId}.jsonl`);
if (!fs.existsSync(sessJsonl)) fail(`session JSONL not found: ${sessJsonl}`);
tier2.push(sessJsonl);
if (fs.existsSync(bm25)) tier2.push(bm25);

if (!tier1.length) fail(`no tier-1 memory found under ${memDir}`);

// ── build payload (staged under out/, NOT /tmp) ───────────────────────────────
fs.mkdirSync(outDir, { recursive: true });
const ts = new Date().toISOString().replace(/[:.]/g, "-");
const fp8 = machineFp.slice(0, 8);
let payloadSha = null, payloadSize = 0, payloadPath = null, ephemeralPubB64 = null, nonceB64 = null, tagB64 = null;

if (!dryRun) {
  const stage = path.join(outDir, `.stage-${ts}`);
  mkdirp(path.join(stage, "sessions"));
  for (const f of tier1) {
    const dest = path.join(stage, stagedAs.get(f) || path.join("memory", path.basename(f)));
    mkdirp(path.dirname(dest));
    fs.copyFileSync(f, dest);
  }
  fs.copyFileSync(sessJsonl, path.join(stage, "sessions", `${sessionId}.jsonl`));
  if (fs.existsSync(bm25)) fs.copyFileSync(bm25, path.join(stage, "memory-index.db"));
  const plainPath = path.join(outDir, `substrate-${ts}-${fp8}.payload.tar.gz`);
  execFileSync("tar", ["-czf", plainPath, "-C", stage, "."]);
  fs.rmSync(stage, { recursive: true, force: true });
  let buf = fs.readFileSync(plainPath);
  if (args.recipient) {
    // α₂: per-export ephemeral X25519 → ECDH → HKDF-SHA256 → ChaCha20-Poly1305
    const eph = crypto.generateKeyPairSync("x25519");
    ephemeralPubB64 = eph.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
    const shared = crypto.diffieHellman({ privateKey: eph.privateKey, publicKey: x25519PubFromRaw(args.recipient) });
    const key = Buffer.from(crypto.hkdfSync("sha256", shared, Buffer.alloc(32), Buffer.from("mae-m3-substrate-v1"), 32));
    const nonce = crypto.randomBytes(12);
    const c = crypto.createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
    const ct = Buffer.concat([c.update(buf), c.final()]);
    nonceB64 = nonce.toString("base64");
    tagB64 = c.getAuthTag().toString("base64");
    payloadPath = path.join(outDir, `substrate-${ts}-${fp8}.payload.enc`);
    fs.writeFileSync(payloadPath, ct);
    fs.rmSync(plainPath, { force: true });
    buf = ct;
  } else {
    payloadPath = plainPath;
  }
  payloadSha = crypto.createHash("sha256").update(buf).digest("hex");
  payloadSize = buf.length;
}

// ── manifest (§3.F) ────────────────────────────────────────────────────────────
const manifest = {
  format_version: "m3-alpha-1",
  exporter_pubkey: edPubRawB64,
  recipient_pubkey: args.recipient || null, // α₂: ECDH target
  ephemeral_pubkey: ephemeralPubB64,         // α₂: per-export X25519 pub
  nonce_b64: nonceB64,                        // α₂: ChaCha20-Poly1305 nonce
  auth_tag_b64: tagB64,                       // α₂: AEAD tag
  exported_at: new Date().toISOString(),
  source_machine_fingerprint: machineFp,
  source_session_id: sessionId,
  tier_1_paths: tier1.map((f) => rel(f)),
  tier_2_paths: tier2.map((f) => rel(f)),
  tier_3_paths: [],
  exclusion_filter: EXCLUSION,
  payload_sha256: payloadSha,
  payload_size_bytes: payloadSize,
  encryption: dryRun ? "none(dry-run)" : (args.recipient ? "x25519-ecdh+chacha20-poly1305" : "none(alpha-1)"),
  notes: args.notes || "",
};
const canon = canonical(manifest);
const sig = crypto.sign(null, Buffer.from(canon), priv).toString("base64");

const manPath = path.join(outDir, `substrate-${ts}-${fp8}.manifest.json`);
const sigPath = path.join(outDir, `substrate-${ts}-${fp8}.manifest.sig`);
fs.writeFileSync(manPath, JSON.stringify(manifest, null, 2) + "\n");
fs.writeFileSync(sigPath, sig + "\n");

// self-verify (prove the sig validates with stdlib)
const ok = crypto.verify(null, Buffer.from(canon), pub, Buffer.from(sig, "base64"));

console.log(JSON.stringify({
  ok, dryRun, exporter_fp8: fp8, exported_at: manifest.exported_at,
  tier1_files: tier1.length, tier2_files: tier2.length,
  payload: payloadPath ? { path: payloadPath, bytes: payloadSize, sha256: payloadSha.slice(0, 16) + "…" } : null,
  manifest: manPath, signature: sigPath, sig_self_verify: ok,
}, null, 2));
if (!ok) process.exit(1);

// ── helpers ──────────────────────────────────────────────────────────────────
function rel(f) { return f.startsWith(HOME) ? "~" + f.slice(HOME.length) : f; }
function x25519PubFromRaw(b64) {
  const der = Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), Buffer.from(b64, "base64")]);
  return crypto.createPublicKey({ key: der, format: "der", type: "spki" });
}
function mkdirp(d) { fs.mkdirSync(d, { recursive: true }); }
function canonical(o) {
  if (Array.isArray(o)) return "[" + o.map(canonical).join(",") + "]";
  if (o && typeof o === "object") return "{" + Object.keys(o).sort().map((k) => JSON.stringify(k) + ":" + canonical(o[k])).join(",") + "}";
  return JSON.stringify(o);
}
function parseArgs(a) { const o = {}; for (let i = 0; i < a.length; i++) { if (a[i].startsWith("--")) { const k = a[i].slice(2); o[k] = (i + 1 < a.length && !a[i + 1].startsWith("--")) ? a[++i] : true; } } return o; }
function req(v, n) { if (!v || v === true) fail(`missing ${n}`); return v; }
function fail(m) { console.error("error: " + m); process.exit(1); }
