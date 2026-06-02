// detectConflict.mjs
//
// Naive conflict detector for the demo. Pattern-matches a proposed clinical
// assertion against the current state from the citation card. Hardcoded
// knowledge base for known dangerous-conflict pairs (anticoagulant
// reversal, allergy contraindications). Real production would use a
// proper clinical decision-support knowledge graph or LLM call; for the
// LNCS §7.4 figure, the hardcoded pairs prove the architecture.

import { getCitationCard } from './getCitationCard.mjs';

const CONFLICT_RULES = {
  anticoagulation: [
    {
      currentMatch: /apixaban|eliquis/i,
      proposedMatch: /\b(ffp|fresh frozen plasma|vitamin k|warfarin reversal)\b/i,
      severity: 'critical',
      conflictKind: 'wrong-reversal-agent',
      summary:
        'Patient is on apixaban (DOAC), not warfarin. FFP and vitamin K do NOT reverse apixaban. The correct reversal agent is andexanet alfa (Andexxa) or, if unavailable, 4-factor PCC.',
    },
    {
      currentMatch: /warfarin/i,
      proposedMatch: /andexanet/i,
      severity: 'moderate',
      conflictKind: 'agent-mismatch',
      summary:
        'Patient is on warfarin (vitamin K antagonist), not a DOAC. Andexanet alfa does not reverse warfarin; use FFP, vitamin K, or 4-factor PCC.',
    },
  ],
  allergies: [
    {
      currentMatch: /penicillin/i,
      proposedMatch: /\b(amoxicillin|ampicillin|penicillin|piperacillin)\b/i,
      severity: 'critical',
      conflictKind: 'allergy-violation',
      summary:
        'Patient has documented penicillin allergy (anaphylaxis, 2014). Beta-lactam antibiotics are contraindicated. Consider macrolide, fluoroquinolone, or doxycycline as alternative.',
    },
  ],
};

/**
 * @param {Object} params
 * @param {string} params.patientId
 * @param {string} params.scope
 * @param {string} params.proposedAssertion  — free-text from clinician input
 * @param {string} params.fixturesRoot
 * @returns {Object} { conflict, severity?, conflictKind?, citationCard, summary? }
 */
export function detectConflict({ patientId, scope, proposedAssertion, fixturesRoot }) {
  const card = getCitationCard({ patientId, scope, fixturesRoot });
  if (!card.found) {
    return { conflict: false, citationCard: card };
  }

  const rules = CONFLICT_RULES[scope] ?? [];
  for (const rule of rules) {
    if (rule.currentMatch.test(card.currentAssertion) &&
        rule.proposedMatch.test(proposedAssertion)) {
      return {
        conflict: true,
        severity: rule.severity,
        conflictKind: rule.conflictKind,
        summary: rule.summary,
        proposedAssertion,
        citationCard: card,
      };
    }
  }

  return { conflict: false, citationCard: card, proposedAssertion };
}
