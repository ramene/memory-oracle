import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { getCitationCard } from '../getCitationCard.mjs';
import { detectConflict } from '../detectConflict.mjs';
import { aiOverview } from '../aiOverview.mjs';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

test('citation card surfaces full amendment chain', () => {
  const card = getCitationCard({
    patientId: 'jane-doe-1959',
    scope: 'anticoagulation',
    fixturesRoot: FIXTURES,
  });
  assert.ok(card.found);
  assert.equal(card.supersessionChain.length, 1);
  assert.match(card.currentAssertion, /apixaban/i);
  assert.match(card.originalAssertion, /warfarin/i);
  assert.equal(card.policy, 'amendment-supersedes-original');
  assert.equal(card.sources.length, 2);  // md + amendments file
});

test('detectConflict flags FFP for apixaban patient', () => {
  const result = detectConflict({
    patientId: 'jane-doe-1959',
    scope: 'anticoagulation',
    proposedAssertion: 'administer FFP 2 units for active GI bleed',
    fixturesRoot: FIXTURES,
  });
  assert.equal(result.conflict, true);
  assert.equal(result.severity, 'critical');
  assert.equal(result.conflictKind, 'wrong-reversal-agent');
});

test('detectConflict does NOT flag andexanet for apixaban patient', () => {
  const result = detectConflict({
    patientId: 'jane-doe-1959',
    scope: 'anticoagulation',
    proposedAssertion: 'administer andexanet alfa 800mg IV bolus',
    fixturesRoot: FIXTURES,
  });
  assert.equal(result.conflict, false);
});

test('aiOverview returns structured TL;DR + explanation + sources', () => {
  const conflict = detectConflict({
    patientId: 'jane-doe-1959',
    scope: 'anticoagulation',
    proposedAssertion: 'order FFP 2 units',
    fixturesRoot: FIXTURES,
  });
  const overview = aiOverview(conflict);
  assert.ok(overview);
  assert.match(overview.tldr, /apixaban/i);
  assert.match(overview.tldr, /2026-01-14/);
  assert.match(overview.explanation, /HIPAA/);
  assert.equal(overview.framing, 'decision-support');
  assert.equal(overview.severity, 'critical');
  assert.ok(overview.sources.length >= 2);  // original + at least one amendment
});

test('penicillin allergy violation surfaces with severity=critical', () => {
  const result = detectConflict({
    patientId: 'jane-doe-1959',
    scope: 'allergies',
    proposedAssertion: 'prescribe amoxicillin 500mg PO TID',
    fixturesRoot: FIXTURES,
  });
  assert.equal(result.conflict, true);
  assert.equal(result.severity, 'critical');
  assert.equal(result.conflictKind, 'allergy-violation');
});
