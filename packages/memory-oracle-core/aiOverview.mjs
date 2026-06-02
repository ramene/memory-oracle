// aiOverview.mjs
//
// "AI Overview"-styled mocked LLM responses, modeled after Google's AI
// Overview pattern: TL;DR, multi-paragraph explanation, and sources
// callout. For the LNCS §7.4 demo. Operator confirmed (3c) "mocked LLM
// strings for the demo, real LLM later for production."
//
// Strings are deliberately framed as DECISION SUPPORT, not medical
// advice — surfacing what was already in the citation card, not
// rendering a clinical opinion. (Framing 5a per the plan.)

/**
 * @param {Object} conflictResult — output of detectConflict()
 * @returns {Object} { tldr, explanation, sources, framing }
 */
export function aiOverview(conflictResult) {
  if (!conflictResult.conflict) {
    return null;
  }
  const card = conflictResult.citationCard;
  const author = card.supersessionChain.length > 0
    ? card.supersessionChain[card.supersessionChain.length - 1].author
    : '(original entry)';
  const amendDate = card.supersessionChain.length > 0
    ? card.supersessionChain[card.supersessionChain.length - 1].ts.slice(0, 10)
    : '(no amendment date)';

  const variant = OVERVIEW_VARIANTS[conflictResult.conflictKind];
  if (!variant) {
    return {
      tldr: conflictResult.summary,
      explanation: conflictResult.summary,
      sources: defaultSources(card),
      framing: 'decision-support',
    };
  }

  return {
    tldr: variant.tldr({ author, amendDate, current: card.currentAssertion }),
    explanation: variant.explanation({
      author, amendDate, current: card.currentAssertion,
      proposed: conflictResult.proposedAssertion,
      summary: conflictResult.summary,
    }),
    sources: defaultSources(card),
    framing: 'decision-support',
    severity: conflictResult.severity,
  };
}

const OVERVIEW_VARIANTS = {
  'wrong-reversal-agent': {
    tldr: ({ amendDate }) =>
      `Patient was switched from warfarin to apixaban on ${amendDate}. The reversal agent you've proposed is for warfarin — not apixaban.`,
    explanation: ({ author, amendDate, current, proposed, summary }) =>
`On **${amendDate}**, ${author} amended this patient's anticoagulation record from warfarin to **${current}**. The amendment is a structural supersession — the original warfarin record is preserved for audit, but apixaban is the current standing order.

Your proposed action — **${proposed}** — reflects warfarin-era practice. Apixaban (a direct factor Xa inhibitor) does not respond to FFP or vitamin K in clinically meaningful timeframes. ${summary}

This alert is generated from the patient's amendment chain (HIPAA §164.526 audit trail), not from a clinical AI rendering an opinion. The recommended reversal agent is documented in the amendment record itself.`,
  },

  'allergy-violation': {
    tldr: ({ current }) =>
      `Patient has a documented allergy: ${current}. Your proposed medication is in the same allergen class.`,
    explanation: ({ author, current, proposed, summary }) =>
`This patient's allergy record (currently: **${current}**) was last reviewed by ${author}. Your proposed entry — **${proposed}** — is in the same allergen class.

${summary}

This alert reflects the documented allergy, not a clinical AI judgment. Confirm with the patient before override; if override is clinically necessary, document the rationale.`,
  },

  'agent-mismatch': {
    tldr: ({ current }) =>
      `Patient is on ${current}. The proposed action targets a different drug class.`,
    explanation: ({ current, proposed, summary }) =>
`Current anticoagulant: **${current}**. Proposed: **${proposed}**.

${summary}`,
  },
};

function defaultSources(card) {
  const sources = [];
  if (card.originalAssertion) {
    sources.push({
      label: 'Original record',
      text: card.originalAssertion,
      mtime: card.sources?.find(s => s.kind === 'original')?.mtime,
    });
  }
  for (const a of card.supersessionChain) {
    sources.push({
      label: `Amendment — ${a.ts.slice(0, 10)} — ${a.author}`,
      text: a.reason ?? a.current,
      currentAssertion: a.current,
      mtime: a.ts,
      sidecarId: a.sidecar_id,
    });
  }
  return sources;
}
