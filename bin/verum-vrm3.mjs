#!/usr/bin/env node
// verum-vrm3 — multi-recipient envelope + revocation primitive for git-remote-verum.
//
// Promotes VRM2 (shared namespace key) to VRM3 (per-device recipients).
//
// VRM3 BLOCK LAYOUT (binary)
// ──────────────────────────────────────────────────────────────────
//   magic        4   = 'VRM3'
//   epoch        4   = uint32 BE — increments on every members-set change
//   nonce       12   = ChaCha20-Poly1305 nonce
//   tag         16   = ChaCha20-Poly1305 auth tag
//   nRecipients  1   = number of recipients (1..255)
//   recipients   k × 48 = { pubkeyFP(8) | nonce'(12) | tag'(16) | wrappedDEK(12) }
//                       each recipient gets DEK wrapped via their X25519
//   ct           remaining = ciphertext under DEK
// ──────────────────────────────────────────────────────────────────
//
// DEK = data encryption key (32 bytes, fresh per block, ChaCha20-Poly1305 key)
//   each recipient gets the 12-byte DEK wrapped via per-recipient
//   X25519-ECDH ⇒ HKDF ⇒ ChaCha20-Poly1305 key wrap
//
// REVOCATION SEMANTICS
//   - Operator maintains a members manifest per repo: `verum-members-<ns>.json`
//     { ns, epoch, members: [ { pubkey_x25519, pubkey_ed25519, label, added_at } ],
//       removed: [ { pubkey_x25519, pubkey_ed25519, label, removed_at, epoch_at_removal } ],
//       sig: Ed25519(operator_root) }
//   - `verum-vrm3 add <pubkey>` → append member, bump epoch, re-sign
//   - `verum-vrm3 kick <pubkey>` → move to removed, bump epoch, re-sign
//   - New blocks encrypted only to current `members` set
//   - Old blocks remain readable to whoever had access at that block's epoch
//   - "Black box" effect: kicked device pulls new blocks → no DEK wrap for them
//     → decryption fails → cached old blocks remain readable but no new content
//
// USAGE
//   verum-vrm3 init <namespace>                                    init members manifest
//   verum-vrm3 add <namespace> <ed25519-pub-b64> [--label name]    add a member
//   verum-vrm3 kick <namespace> <ed25519-pub-b64>                  revoke a member
//   verum-vrm3 list <namespace>                                    show members
//   verum-vrm3 encrypt <namespace> <plaintext-file> > block.vrm3   encrypt block to current members
//   verum-vrm3 decrypt <block.vrm3                                  decrypt with local keys
//   verum-vrm3 test-revocation                                     synthetic device, encrypt+verify
//                                                                  +kick+verify black-box

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

const MAGIC = Buffer.from('VRM3', 'ascii');
const VERUM_DIR = path.join(os.homedir(), '.verum');
const ED25519_PRIV = path.join(VERUM_DIR, 'operator-ed25519.key');
const ED25519_PUB  = path.join(VERUM_DIR, 'operator-ed25519.pub');
const X25519_PRIV  = path.join(VERUM_DIR, 'operator-x25519.key');

function fp8(pubBuf) { return crypto.createHash('sha256').update(pubBuf).digest().slice(0, 8); }

// ── Members manifest helpers ────────────────────────────────────────────────
function manifestPath(ns) {
  const safe = ns.replace(/[^A-Za-z0-9_-]/g, '_');
  return path.join(VERUM_DIR, `verum-members-${safe}.json`);
}

function loadManifest(ns) {
  const p = manifestPath(ns);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function signManifest(m) {
  // sign canonical JSON of { ns, epoch, members, removed }
  const { sig: _ignore, ...rest } = m;
  const canonical = JSON.stringify(rest);
  const priv = crypto.createPrivateKey(fs.readFileSync(ED25519_PRIV));
  m.sig = crypto.sign(null, Buffer.from(canonical, 'utf8'), priv).toString('base64url');
  return m;
}

function verifyManifest(m, opPubPemOrKeyObj) {
  if (!m.sig) return false;
  const { sig: _ignore, ...rest } = m;
  const canonical = JSON.stringify(rest);
  const pub = (opPubPemOrKeyObj && opPubPemOrKeyObj.asymmetricKeyType)
    ? opPubPemOrKeyObj
    : crypto.createPublicKey(opPubPemOrKeyObj || fs.readFileSync(ED25519_PUB));
  return crypto.verify(null, Buffer.from(canonical, 'utf8'), pub,
                       Buffer.from(m.sig, 'base64url'));
}

function saveManifest(m) {
  fs.writeFileSync(manifestPath(m.ns), JSON.stringify(m, null, 2));
}

// ── Crypto: per-recipient key wrap via X25519 ECDH + ChaCha20-Poly1305 ──────
function wrapDekForRecipient(dek, recipientX25519PubB64) {
  const recipient = crypto.createPublicKey({
    key: Buffer.concat([
      Buffer.from('302a300506032b656e032100', 'hex'),
      Buffer.from(recipientX25519PubB64, 'base64'),
    ]),
    format: 'der', type: 'spki',
  });
  const ephem = crypto.generateKeyPairSync('x25519');
  const shared = crypto.diffieHellman({ privateKey: ephem.privateKey, publicKey: recipient });
  const kek = crypto.hkdfSync('sha256', shared, Buffer.alloc(0), 'vrm3-keywrap-v1', 32);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('chacha20-poly1305', kek, nonce, { authTagLength: 16 });
  const wrapped = Buffer.concat([cipher.update(dek), cipher.final()]);
  const tag = cipher.getAuthTag();
  const ephPub = ephem.publicKey.export({type:'spki', format:'der'}).slice(-32);
  return { ephPub, nonce, tag, wrapped, fp: fp8(recipient.export({type:'spki', format:'der'}).slice(-32)) };
}

function unwrapDekWithLocalKey(blob, x25519PrivPath) {
  const priv = crypto.createPrivateKey(fs.readFileSync(x25519PrivPath));
  const ephem = crypto.createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), blob.ephPub]),
    format: 'der', type: 'spki',
  });
  const shared = crypto.diffieHellman({ privateKey: priv, publicKey: ephem });
  const kek = crypto.hkdfSync('sha256', shared, Buffer.alloc(0), 'vrm3-keywrap-v1', 32);
  const decipher = crypto.createDecipheriv('chacha20-poly1305', kek, blob.nonce, { authTagLength: 16 });
  decipher.setAuthTag(blob.tag);
  return Buffer.concat([decipher.update(blob.wrapped), decipher.final()]);
}

// ── Encrypt / decrypt a block ───────────────────────────────────────────────
// Recipients list = array of { pubX25519_b64 }
function encryptBlock(plaintext, recipients, epoch) {
  const dek = crypto.randomBytes(32);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('chacha20-poly1305', dek, nonce, { authTagLength: 16 });
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  const recipBlobs = recipients.map(r => wrapDekForRecipient(dek, r.pubX25519_b64));
  if (recipBlobs.length > 255) throw new Error('VRM3 supports max 255 recipients per block');

  const epochBuf = Buffer.alloc(4);
  epochBuf.writeUInt32BE(epoch >>> 0, 0);
  const recipBuf = Buffer.concat(recipBlobs.map(b =>
    Buffer.concat([b.fp, b.ephPub, b.nonce, b.tag, b.wrapped])));

  return Buffer.concat([
    MAGIC, epochBuf, nonce, tag,
    Buffer.from([recipBlobs.length]),
    recipBuf,
    ct,
  ]);
}

function decryptBlock(buf, x25519PrivPath, x25519PubB64Local) {
  if (!buf.slice(0, 4).equals(MAGIC)) throw new Error('not a VRM3 block');
  const epoch = buf.readUInt32BE(4);
  const nonce = buf.slice(8, 20);
  const tag = buf.slice(20, 36);
  const n = buf[36];
  const recipStart = 37;
  const recipSize = 8 + 32 + 12 + 16 + 32;  // fp + ephPub + nonce + tag + wrapped(32)
  // Find OUR recipient by fingerprint
  const myFp = fp8(Buffer.from(x25519PubB64Local, 'base64'));
  let myBlob = null;
  for (let i = 0; i < n; i++) {
    const off = recipStart + i * recipSize;
    const fp = buf.slice(off, off + 8);
    if (fp.equals(myFp)) {
      myBlob = {
        fp,
        ephPub:  buf.slice(off + 8,  off + 40),
        nonce:   buf.slice(off + 40, off + 52),
        tag:     buf.slice(off + 52, off + 68),
        wrapped: buf.slice(off + 68, off + 100),
      };
      break;
    }
  }
  if (!myBlob) throw new Error('BLACK_BOX: no recipient slot for this device — has access been revoked?');
  const dek = unwrapDekWithLocalKey(myBlob, x25519PrivPath);
  const ctStart = recipStart + n * recipSize;
  const ct = buf.slice(ctStart);
  const decipher = crypto.createDecipheriv('chacha20-poly1305', dek, nonce, { authTagLength: 16 });
  decipher.setAuthTag(tag);
  return { plaintext: Buffer.concat([decipher.update(ct), decipher.final()]), epoch };
}

// ── X25519 pub from local private key ───────────────────────────────────────
function localX25519PubB64() {
  const priv = crypto.createPrivateKey(fs.readFileSync(X25519_PRIV));
  const pub = crypto.createPublicKey(priv);
  const der = pub.export({type:'spki', format:'der'});
  return der.slice(-32).toString('base64');
}

// ── CLI ─────────────────────────────────────────────────────────────────────
function usage() {
  console.error(`usage: verum-vrm3 <op> [args]
  init <ns>                                          init members manifest
  add <ns> <x25519-pub-b64> [--label name]           add a member
  kick <ns> <x25519-pub-b64>                         revoke a member
  list <ns>                                          show members
  encrypt <ns> <plaintext-file>                      encrypt to current members (writes to stdout)
  decrypt                                            read block from stdin, decrypt with local x25519 key
  test-revocation                                    synthetic-device round-trip + black-box proof`);
  process.exit(2);
}

async function main() {
  const [op, ...args] = process.argv.slice(2);
  if (!op) usage();

  if (op === 'init') {
    const ns = args[0]; if (!ns) usage();
    if (fs.existsSync(manifestPath(ns))) { console.error(`exists: ${manifestPath(ns)}`); process.exit(1); }
    const operatorX = localX25519PubB64();
    const m = signManifest({
      ns, epoch: 1,
      members: [{ pubX25519_b64: operatorX, label: 'operator', added_at: new Date().toISOString() }],
      removed: [],
    });
    saveManifest(m);
    console.log(`✓ init ${ns} (manifest: ${manifestPath(ns).replace(os.homedir(), '~')})`);
    return;
  }

  if (op === 'list') {
    const ns = args[0]; if (!ns) usage();
    const m = loadManifest(ns); if (!m) { console.error(`no such ns: ${ns}`); process.exit(1); }
    console.log(JSON.stringify(m, null, 2));
    return;
  }

  if (op === 'add' || op === 'kick') {
    const ns = args[0], pub = args[1]; if (!ns || !pub) usage();
    const label = args[args.indexOf('--label')+1] && args[args.indexOf('--label')+1] !== '--label'
                  ? args[args.indexOf('--label')+1] : null;
    const m = loadManifest(ns); if (!m) { console.error(`no such ns: ${ns}`); process.exit(1); }
    if (op === 'add') {
      if (m.members.some(x => x.pubX25519_b64 === pub)) { console.error('already a member'); process.exit(1); }
      m.members.push({ pubX25519_b64: pub, label: label || 'unnamed', added_at: new Date().toISOString() });
    } else {
      const idx = m.members.findIndex(x => x.pubX25519_b64 === pub);
      if (idx < 0) { console.error('not a member'); process.exit(1); }
      const removed = m.members.splice(idx, 1)[0];
      m.removed.push({ ...removed, removed_at: new Date().toISOString(), epoch_at_removal: m.epoch });
    }
    m.epoch++;
    signManifest(m);
    saveManifest(m);
    console.log(`✓ ${op} ${pub.slice(0,16)}... → epoch=${m.epoch} members=${m.members.length}`);
    return;
  }

  if (op === 'encrypt') {
    const ns = args[0], file = args[1]; if (!ns || !file) usage();
    const m = loadManifest(ns); if (!m) { console.error(`no such ns: ${ns}`); process.exit(1); }
    if (!verifyManifest(m, ED25519_PUB)) { console.error('manifest signature INVALID'); process.exit(1); }
    const pt = fs.readFileSync(file);
    const block = encryptBlock(pt, m.members, m.epoch);
    process.stdout.write(block);
    return;
  }

  if (op === 'decrypt') {
    // Read full stdin
    const chunks = [];
    for await (const c of process.stdin) chunks.push(c);
    const buf = Buffer.concat(chunks);
    try {
      const { plaintext, epoch } = decryptBlock(buf, X25519_PRIV, localX25519PubB64());
      process.stdout.write(plaintext);
      process.stderr.write(`\n✓ decrypted (epoch=${epoch})\n`);
    } catch (e) {
      process.stderr.write(`✗ ${e.message}\n`);
      process.exit(1);
    }
    return;
  }

  if (op === 'test-revocation') {
    // Generate synthetic device, add as recipient, encrypt+verify, kick, encrypt+verify BLACK BOX
    console.log('═══ VRM3 test-revocation ═══');
    const synth = crypto.generateKeyPairSync('x25519');
    const synthPubB64 = synth.publicKey.export({type:'spki', format:'der'}).slice(-32).toString('base64');
    const synthPrivPath = '/tmp/vrm3-synth-' + Date.now() + '.key';
    fs.writeFileSync(synthPrivPath, synth.privateKey.export({type:'pkcs8', format:'pem'}));
    fs.chmodSync(synthPrivPath, 0o600);
    console.log(`  synthetic device pub: ${synthPubB64.slice(0,32)}...`);

    const ns = 'vrm3-test-' + Date.now();
    let m = signManifest({
      ns, epoch: 1,
      members: [
        { pubX25519_b64: localX25519PubB64(), label: 'operator', added_at: new Date().toISOString() },
        { pubX25519_b64: synthPubB64, label: 'synth-bob', added_at: new Date().toISOString() },
      ],
      removed: [],
    });
    saveManifest(m);
    console.log(`  ✓ created members manifest (2 members, epoch=1)`);

    // Encrypt a test block
    const pt = Buffer.from('top secret — this is the substrate at epoch 1');
    const block1 = encryptBlock(pt, m.members, m.epoch);
    console.log(`  ✓ encrypted block (${block1.length} bytes, ${m.members.length} recipients)`);

    // Synth device can decrypt
    const { plaintext: r1 } = decryptBlock(block1, synthPrivPath, synthPubB64);
    console.log(`  ✓ synth decrypts: "${r1.toString().slice(0, 40)}..."`);

    // Now kick the synth device
    m.removed.push({ ...m.members.pop(), removed_at: new Date().toISOString(), epoch_at_removal: m.epoch });
    m.epoch++;
    signManifest(m);
    saveManifest(m);
    console.log(`  ⚠ KICKED synth-bob → epoch=${m.epoch} members=${m.members.length}`);

    // Encrypt a NEW block under the new members set
    const pt2 = Buffer.from('top secret — this is epoch 2, after revocation');
    const block2 = encryptBlock(pt2, m.members, m.epoch);
    console.log(`  ✓ encrypted new block at epoch=${m.epoch} (${block2.length} bytes, ${m.members.length} recipients)`);

    // Synth tries to decrypt the NEW block — should BLACK BOX
    try {
      decryptBlock(block2, synthPrivPath, synthPubB64);
      console.log(`  ✗ FAIL — synth could still decrypt new block (revocation NOT working)`);
      process.exit(1);
    } catch (e) {
      console.log(`  ✓ synth-bob is BLACK-BOXED on new block: "${e.message}"`);
    }

    // Synth can still decrypt the OLD block (epoch 1 era)
    const { plaintext: r1b } = decryptBlock(block1, synthPrivPath, synthPubB64);
    console.log(`  ✓ synth-bob can still decrypt epoch-1 block (epoch isolation works): "${r1b.toString().slice(0, 40)}..."`);

    // Cleanup
    fs.unlinkSync(synthPrivPath);
    fs.unlinkSync(manifestPath(ns));
    console.log('  ✓ cleanup');
    console.log('═══ TEST PASSED — revocation provably works ═══');
    return;
  }

  usage();
}

main().catch(e => { console.error(`fatal: ${e.message}`); process.exit(1); });
