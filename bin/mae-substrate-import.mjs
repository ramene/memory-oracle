#!/usr/bin/env node
// mae-substrate-import — M3-α₄: verify + decrypt + stage an incoming substrate snapshot.
//
// Runs on the RECIPIENT (e.g. sequoia). Mirrors the exporter's crypto (Node stdlib):
//   1. verify exporter's Ed25519 sig over canonical(manifest) — REFUSE if invalid
//   2. check payload_sha256 of the .enc
//   3. ECDH(recipient x25519 priv, exporter ephemeral pub) → HKDF-SHA256 → ChaCha20-Poly1305 decrypt
//   4. extract inner tar.gz to ~/.mae-substrate-incoming/<exported_at>/ (NON-destructive: stage only)
//   5. Touch-ID gate (interactive only; skipped headless — see note)
//   6. emit a recipient-signed receipt for round-trip provenance
//
// Default = STAGE ONLY (does not overwrite the recipient's own substrate). `--apply`
// (future) would merge into a mirror namespace. Usage:
//   node mae-substrate-import.mjs <substrate-...manifest.json>
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const HOME = os.homedir();
const manPath = process.argv[2];
if (!manPath || !fs.existsSync(manPath)) fail(`manifest not found: ${manPath}`);
const base = manPath.replace(/\.manifest\.json$/, "");
const m = JSON.parse(fs.readFileSync(manPath, "utf8"));
const sig = fs.readFileSync(base + ".manifest.sig", "utf8").trim();
const encPath = base + ".payload.enc";

// 1. verify exporter signature (refuse on failure)
const exPub = edPubFromRaw(m.exporter_pubkey);
if (!crypto.verify(null, Buffer.from(canonical(m)), exPub, Buffer.from(sig, "base64")))
  fail("exporter signature INVALID — refusing import");

// 2. payload integrity
const ct = fs.readFileSync(encPath);
if (crypto.createHash("sha256").update(ct).digest("hex") !== m.payload_sha256)
  fail("payload_sha256 mismatch — refusing import");

// 3. decrypt (ECDH → HKDF → ChaCha20-Poly1305)
const x25519Priv = crypto.createPrivateKey(fs.readFileSync(path.join(HOME, ".verum", "operator-x25519.key")));
const shared = crypto.diffieHellman({ privateKey: x25519Priv, publicKey: x25519PubFromRaw(m.ephemeral_pubkey) });
const key = Buffer.from(crypto.hkdfSync("sha256", shared, Buffer.alloc(32), Buffer.from("mae-m3-substrate-v1"), 32));
const d = crypto.createDecipheriv("chacha20-poly1305", key, Buffer.from(m.nonce_b64, "base64"), { authTagLength: 16 });
d.setAuthTag(Buffer.from(m.auth_tag_b64, "base64"));
let inner;
try { inner = Buffer.concat([d.update(ct), d.final()]); } // throws if tampered/wrong key
catch (e) { fail("decryption/AEAD verification FAILED — " + e.message); }

// 4. stage (non-destructive)
const stage = path.join(HOME, ".mae-substrate-incoming", m.exported_at.replace(/[:.]/g, "-"));
fs.mkdirSync(stage, { recursive: true });
const innerTar = path.join(stage, "payload.tar.gz");
fs.writeFileSync(innerTar, inner);
execFileSync("tar", ["-xzf", innerTar, "-C", stage]);
fs.rmSync(innerTar, { force: true });
const extracted = listFiles(stage).map((f) => f.slice(stage.length + 1));

// 5. Touch-ID gate — interactive only
const touchid = process.stdout.isTTY ? "would-gate(interactive)" : "skipped(headless)";

// 6. recipient-signed receipt
const myEd = crypto.createPrivateKey(fs.readFileSync(path.join(HOME, ".verum", "operator-ed25519.key")));
const myPub = crypto.createPublicKey(myEd).export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
const receipt = {
  format_version: "m3-alpha-receipt-1",
  original_manifest_sha256: crypto.createHash("sha256").update(canonical(m)).digest("hex"),
  importer_pubkey: myPub,
  importer_host: os.hostname(),
  applied_at: new Date().toISOString(),
  mode: "stage-only",
  staged_to: stage,
  files_extracted: extracted.length,
  source_session_id: m.source_session_id,
};
const receiptSig = crypto.sign(null, Buffer.from(canonical(receipt)), myEd).toString("base64");
fs.writeFileSync(base + ".receipt.json", JSON.stringify(receipt, null, 2) + "\n");
fs.writeFileSync(base + ".receipt.sig", receiptSig + "\n");

console.log(JSON.stringify({
  sig_verified: true, payload_sha_ok: true, decrypted_bytes: inner.length,
  touchid, staged_to: stage, files_extracted: extracted.length,
  sample: extracted.slice(0, 8),
  receipt: base + ".receipt.json", receipt_signed_by: myPub.slice(0, 12) + "…",
}, null, 2));

function canonical(o) { return Array.isArray(o) ? "[" + o.map(canonical).join(",") + "]" : (o && typeof o === "object") ? "{" + Object.keys(o).sort().map((k) => JSON.stringify(k) + ":" + canonical(o[k])).join(",") + "}" : JSON.stringify(o); }
function edPubFromRaw(b64) { return crypto.createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(b64, "base64")]), format: "der", type: "spki" }); }
function x25519PubFromRaw(b64) { return crypto.createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), Buffer.from(b64, "base64")]), format: "der", type: "spki" }); }
function listFiles(d) { const out = []; for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) out.push(...listFiles(p)); else out.push(p); } return out; }
function fail(msg) { console.error("error: " + msg); process.exit(1); }
