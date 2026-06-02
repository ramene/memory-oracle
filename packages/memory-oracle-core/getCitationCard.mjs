// getCitationCard.mjs
//
// Task #68 — Node implementation of accretion.get_citation_card().
// Returns a structured citation card surfacing the full provenance for a
// scoped patient assertion: original assertion text, amendment chain
// (timestamps + authors + supersession reasons), source file references
// with mtime + sha256, and the policy that determines current truth.
//
// Currently file-system backed: reads fixtures from a corpus root dir,
// parses .md (original assertion) + .md.amendments.jsonl (amendment chain).
// Same format the operator's live memory bank uses (per memory-merge.mjs
// 2026-05-31 backwards-compat fix: prefers .amendments.jsonl, falls back
// to .supersessions.jsonl).
//
// Go parity (other half of Task #68) is post-paper.

import { readFileSync, statSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';
import { createHash } from 'node:crypto';

/**
 * @param {Object} params
 * @param {string} params.patientId       — e.g. "jane-doe-1959"
 * @param {string} params.scope           — e.g. "anticoagulation"
 * @param {string} params.fixturesRoot    — root dir containing <patientId>/<scope>.md
 * @returns {Object} citation card
 */
export function getCitationCard({ patientId, scope, fixturesRoot }) {
  const patientDir = join(fixturesRoot, patientId);
  const mdPath     = join(patientDir, `${scope}.md`);
  const amendsPath = join(patientDir, `${scope}.md.amendments.jsonl`);

  if (!existsSync(mdPath)) {
    return {
      patientId, scope,
      found: false,
      error: `No record at ${mdPath}`,
    };
  }

  const originalText = readFileSync(mdPath, 'utf8');
  const originalStat = statSync(mdPath);
  const originalSha  = sha256(originalText);
  const originalAssertion = extractAssertion(originalText, scope);

  const supersessionChain = existsSync(amendsPath)
    ? parseAmendments(readFileSync(amendsPath, 'utf8'))
    : [];

  const currentAssertion = supersessionChain.length > 0
    ? supersessionChain[supersessionChain.length - 1].current
    : originalAssertion;

  const sources = [
    {
      kind: 'original',
      path: mdPath,
      mtime: originalStat.mtime.toISOString(),
      sha256: originalSha,
    },
  ];
  if (existsSync(amendsPath)) {
    const aStat = statSync(amendsPath);
    sources.push({
      kind: 'amendments',
      path: amendsPath,
      mtime: aStat.mtime.toISOString(),
      sha256: sha256(readFileSync(amendsPath, 'utf8')),
    });
  }

  return {
    patientId,
    scope,
    found: true,
    currentAssertion,
    originalAssertion,
    supersessionChain,
    sources,
    policy: 'amendment-supersedes-original',
    policyExplanation:
      'When an amendment exists, it elevates over the original. Multiple amendments compose in temporal order: latest amendment becomes current truth. Original is retained for full audit trail per HIPAA §164.526.',
  };
}

function parseAmendments(jsonl) {
  const out = [];
  for (const line of jsonl.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      out.push(JSON.parse(trimmed));
    } catch (e) {
      // skip malformed lines (defensive — operator's real corpus is sound)
    }
  }
  // Sort by ts ascending so chain reads chronologically
  return out.sort((a, b) => (a.ts ?? '').localeCompare(b.ts ?? ''));
}

function extractAssertion(mdText, scope) {
  // Heuristic: pick the first non-heading, non-empty line as the assertion.
  // Real EBR would have structured fields; for the demo this is enough.
  for (const raw of mdText.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('#')) continue;
    if (line.startsWith('-')) {
      return line.replace(/^-\s*/, '');
    }
    if (line.startsWith('**')) continue;
    return line;
  }
  return `(no extractable assertion for ${scope})`;
}

function sha256(s) {
  return createHash('sha256').update(s).digest('hex');
}
