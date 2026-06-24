#!/usr/bin/env node
// mae-verum-pubkeys — print THIS machine's verum PUBLIC keys (raw b64) + private-key
// PATHS for the M3 key registry. PUBLIC keys + paths only — private material never
// printed/transferred. `--gen-x25519` creates the x25519 keypair if absent (private
// key written 0600, stays on the box).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const H = os.homedir();
const dir = path.join(H, ".verum");
const edPath = process.env.VERUM_IDENTITY_KEY || path.join(dir, "operator-ed25519.key");
const xPath = path.join(dir, "operator-x25519.key");

if (process.argv.includes("--gen-x25519") && !fs.existsSync(xPath)) {
  fs.mkdirSync(dir, { recursive: true });
  const k = crypto.generateKeyPairSync("x25519");
  fs.writeFileSync(xPath, k.privateKey.export({ type: "pkcs8", format: "pem" }));
  fs.chmodSync(xPath, 0o600);
}
if (process.argv.includes("--gen-ed25519") && !fs.existsSync(edPath)) {
  fs.mkdirSync(dir, { recursive: true });
  const k = crypto.generateKeyPairSync("ed25519");
  fs.writeFileSync(edPath, k.privateKey.export({ type: "pkcs8", format: "pem" }));
  fs.chmodSync(edPath, 0o600);
}

const out = { host: os.hostname() };
for (const [t, p] of [["ed25519", edPath], ["x25519", xPath]]) {
  try {
    const pub = crypto.createPublicKey(crypto.createPrivateKey(fs.readFileSync(p)));
    out[t] = { pub_b64: pub.export({ type: "spki", format: "der" }).subarray(-32).toString("base64"), priv_path: p.replace(H, "~"), present: true };
  } catch { out[t] = { present: false, priv_path: p.replace(H, "~") }; }
}
console.log(JSON.stringify(out));
