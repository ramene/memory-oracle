#!/usr/bin/env python3
"""Render per-lesson MARKETING COPY from Whisper transcript + voice-spec.

Outputs an LLM-ready prompt that, when fed to Claude/GPT/etc, produces:
  - 5 alternative HOOKS (each targeting a different Life-Force-8 anchor)
  - A Substack opening paragraph
  - A 5-tweet X/Twitter thread
  - A LinkedIn long-form post
  - A short-form (60s) video script
  - A "save-worthy" carousel for Instagram/LinkedIn
  - 3 reply-bait questions for the comments

All grounded in:
  - MikoAI Life-Force-8 (biological desires)
  - MikoAI CLARCCS (Cialdini's 6 triggers — Comparison/Liking/Authority/Reciprocity/Consistency/Scarcity)
  - MikoAI Tension-Desire-Action
  - Operator's voice-spec.yaml

Zero autonomous LLM spend; the renderer emits the prompt, you control the call.
"""
from __future__ import annotations
import argparse, json, re, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


DEFAULT_INPUT      = Path.home() / ".local/share/nightcode-transcripts"

def _resolve_voice_spec() -> Path:
    """Prefer voice-spec-alternative.yaml (operator's filled-in brand voice);
    fall back to voice-spec.yaml (the MikoAI template with TODOs)."""
    base = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/brand-spine/avatar"
    alt = base / "voice-spec-alternative.yaml"
    canonical = base / "voice-spec.yaml"
    return alt if alt.exists() else canonical

DEFAULT_VOICE_SPEC = _resolve_voice_spec()
DEFAULT_OUTPUT     = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/brand-spine/nightcode-marketing"


def load_voice_spec(path: Path) -> dict:
    if not path.exists():
        return {"_error": f"voice-spec not found at {path}"}
    raw = path.read_text()
    if yaml is None:
        return {"_error": "PyYAML not installed", "_raw": raw}
    try:
        return yaml.safe_load(raw) or {}
    except Exception as e:
        return {"_error": f"YAML parse failed: {e}", "_raw": raw}


def todo_or(v, fallback="<TODO from voice-spec>"):
    if v is None or v == "TODO" or (isinstance(v, str) and v.strip().upper() == "TODO"):
        return fallback
    if isinstance(v, list):
        return ", ".join(str(x) for x in v) if v else fallback
    return str(v)


def render_prompt(transcript: dict, spec: dict) -> str:
    idx = transcript["lesson_idx"]
    duration = transcript.get("duration_sec", 0)
    text = transcript.get("text", "")
    segments = transcript.get("segments", [])

    persona = (spec or {}).get("persona", {}) or {}
    niche = (spec or {}).get("niche", {}) or {}
    lf8 = (spec or {}).get("life_force_8_emphasis", {}) or {}
    clarccs = (spec or {}).get("clarccs_emphasis", {}) or {}
    platforms = (spec or {}).get("platforms", {}) or {}
    commitments = (spec or {}).get("brand_commitments", {}) or {}

    out = []
    out.append(f"# Lesson {idx} — Marketing Copy Generation Prompt\n")
    out.append("> Paste into Claude/GPT/etc. Provider-agnostic. No autonomous spend here.\n\n")
    out.append("---\n\n")

    out.append("## 1. Your role\n\n")
    out.append("You are an expert direct-response copywriter who has internalized:\n")
    out.append("- **MikoAI Life-Force-8** (biological desires)\n")
    out.append("- **MikoAI CLARCCS** (Cialdini's 6 psychological triggers: Comparison, Liking, Authority, Reciprocity, Consistency/Commitment, Scarcity)\n")
    out.append("- **MikoAI Tension-Desire-Action** narrative arc\n")
    out.append("- **MikoAI Mental Movies** (specific, sensory, visual language — never vague)\n\n")
    out.append("You write for the operator's voice (below) about their niche (below), grounded in the actual content of their re-implementation of Antonio Erdeljac's nightcode workshop. You produce ORIGINAL marketing copy that promotes the operator's version — you do NOT promote Antonio's content.\n\n")

    out.append("## 2. Voice-spec\n\n")
    out.append("```yaml\n")
    out.append(f"persona_name:           {todo_or(persona.get('name'))}\n")
    out.append(f"archetype:              {todo_or(persona.get('archetype'))}\n")
    out.append(f"niche_primary:          {todo_or(niche.get('primary'))}\n")
    out.append(f"niche_sub:              {todo_or(niche.get('sub_niche'))}\n")
    out.append(f"target_audience:        {todo_or(niche.get('target_audience'))}\n")
    out.append(f"audience_pain_phrases:  {todo_or(lf8.get('audience_pain_phrases'))}\n")
    out.append(f"\n")
    out.append(f"life_force_8_primary:   {todo_or(lf8.get('primary'))}\n")
    out.append(f"life_force_8_secondary: {todo_or(lf8.get('secondary'))}\n")
    out.append(f"life_force_8_tertiary:  {todo_or(lf8.get('tertiary'))}\n")
    out.append(f"\n")
    out.append(f"clarccs_triggers:       {todo_or(clarccs.get('triggers'))}\n")
    out.append(f"\n")
    out.append(f"platforms_primary:      {todo_or(platforms.get('primary'))}\n")
    out.append(f"platforms_secondary:    {todo_or(platforms.get('secondary'))}\n")
    out.append(f"cta_per_post:           {todo_or((platforms.get('monetization', {}) or {}).get('cta_per_post'))}\n")
    out.append(f"\n")
    out.append(f"brand_commitments:\n")
    for k, v in (commitments or {}).items() if isinstance(commitments, dict) else []:
        out.append(f"  - {k}: {todo_or(v)}\n")
    out.append("```\n\n")

    out.append("## 3. Source material — Antonio's lesson {idx}\n\n".format(idx=idx))
    out.append(f"**Duration:** {duration/60:.1f} min  ·  **Words:** {len(text.split())}\n\n")
    out.append(f"**Full transcript (verbatim from Whisper):**\n\n")
    out.append("```\n")
    for s in segments:
        out.append(f"[{s['start']:6.1f}s] {s['text'].strip()}\n")
    out.append("```\n\n")

    out.append("## 4. What you produce (in this exact order)\n\n")
    out.append("### A. 5 alternative HOOKS\n\n")
    out.append("Each hook is 1-2 lines, designed to stop the scroll. Each targets a DIFFERENT Life-Force-8 anchor — note which one inline. Use Mental-Movies (sensory specifics). NEVER vague.\n\n")
    out.append("Example shape:\n")
    out.append("```\n")
    out.append("HOOK 1 [LF8: Superiority]: <line>\n")
    out.append("HOOK 2 [LF8: Freedom from fear]: <line>\n")
    out.append("HOOK 3 [LF8: Social approval]: <line>\n")
    out.append("HOOK 4 [LF8: Comfortable living]: <line>\n")
    out.append("HOOK 5 [LF8: Care for loved ones — re-cast for B2B as 'team safety']: <line>\n")
    out.append("```\n\n")

    out.append("### B. Substack opening paragraph (200-300 words)\n\n")
    out.append("Open with the strongest HOOK from A. Build T-D-A: tension → desire → action. Close with a CTA from voice-spec.\n\n")

    out.append("### C. 5-tweet X/Twitter thread\n\n")
    out.append("- Tweet 1 = strongest HOOK from A (must stand alone — no thread expectation)\n")
    out.append("- Tweets 2-4 = build the T-D-A arc, one beat per tweet, end each with a hook into the next\n")
    out.append("- Tweet 5 = CTA + link\n")
    out.append("- CLARCCS hits: identify which trigger each tweet activates inline\n\n")

    out.append("### D. LinkedIn long-form post (400-600 words)\n\n")
    out.append("LinkedIn audience is more measured. Lead with AUTHORITY (CLARCCS trigger 3). Less raw emotion, more concrete-outcome framing. Cite specific lessons-learned. Close with a question to bait comments.\n\n")

    out.append("### E. 60-second short-form video script\n\n")
    out.append("For Reels/Shorts/X-video. Pattern Interrupt opening (3 sec). Mental-Movies body (40 sec). Empowerment close (15 sec). Format:\n")
    out.append("```\n")
    out.append("[0:00-0:03] HOOK: <line> [VISUAL: <screen>]\n")
    out.append("[0:03-0:40] BODY: <lines> [VISUAL: <screen>]\n")
    out.append("[0:40-0:60] CLOSE: <line + CTA> [VISUAL: <screen>]\n")
    out.append("```\n\n")

    out.append("### F. Save-worthy carousel (8 slides)\n\n")
    out.append("For Instagram + LinkedIn carousels. Each slide is 1-line + 1 mini-illustration concept.\n")
    out.append("- Slide 1: HOOK (the strongest from A)\n")
    out.append("- Slides 2-7: ONE insight per slide (the lesson's actual teaching points)\n")
    out.append("- Slide 8: CTA + save-prompt (\"Save this for when you're building yours\")\n\n")

    out.append("### G. 3 reply-bait questions\n\n")
    out.append("Questions you'd post as the FIRST COMMENT on each platform post. Designed to provoke specific kinds of replies that boost engagement without engagement-farming. Be honest, not manipulative.\n\n")

    out.append("## 5. Constraints (ABSOLUTE — never violate)\n\n")
    out.append("- NEVER mention Antonio's specific vendor choices (Clerk, Polar) as if they were the operator's. Use the operator's stack: NextAuth, Stripe direct, GAE, Cloud SQL, Verum.\n")
    out.append("- NEVER claim the operator built this with Antonio. The frame is: \"Antonio's pedagogical arc is the structural reference; this is my re-implementation in [niche] for [audience].\"\n")
    out.append("- NEVER use fake urgency or fake scarcity. The Scarcity CLARCCS trigger is OK when real (e.g., \"first 50 paid subscribers get a live Q&A with me\").\n")
    out.append("- NEVER publish credentials, internal paths, or anything from the voice-spec marked sensitive.\n")
    out.append("- IF voice-spec has `<TODO from voice-spec>` placeholders, mark the affected output sections as `[FILL VOICE-SPEC BEFORE PUBLISHING]` rather than guessing.\n\n")

    out.append("## 6. Final check before delivering\n\n")
    out.append("After generating all sections, score yourself:\n")
    out.append("- Does every Hook use a Mental Movie (sensory specifics)? \n")
    out.append("- Does every section tap at least 1 Life-Force-8 desire from voice-spec?\n")
    out.append("- Does every section use at least 1 CLARCCS trigger from voice-spec?\n")
    out.append("- Is the Substack section ≥ 200 words and the LinkedIn ≥ 400 words?\n")
    out.append("- Did you avoid every brand_commitment violation?\n")
    out.append("- If any answer is no, REVISE before delivering.\n\n")
    out.append("Now generate the copy.\n")

    return "".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT)
    p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument("--voice-spec", type=Path, default=DEFAULT_VOICE_SPEC)
    p.add_argument("--only", type=int, nargs="*")
    p.add_argument("--force", action="store_true")
    args = p.parse_args(argv)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    spec = load_voice_spec(args.voice_spec)
    if "_error" in spec:
        print(f"  ⚠️  voice-spec: {spec['_error']}", file=sys.stderr)

    transcripts = sorted(args.input_dir.glob("lesson*-transcript.json"))
    if args.only:
        transcripts = [t for t in transcripts if int(re.search(r"lesson(\d+)", t.name).group(1)) in args.only]

    written = skipped = 0
    for tp in transcripts:
        data = json.loads(tp.read_text())
        idx = data["lesson_idx"]
        out = args.output_dir / f"l{idx:02d}-marketing-prompt.md"
        if out.exists() and not args.force:
            print(f"  L{idx:02d}  skip")
            skipped += 1
            continue
        out.write_text(render_prompt(data, spec))
        print(f"  L{idx:02d}  ✓ {out.name} ({out.stat().st_size//1024} KB)")
        written += 1

    print(f"\nSummary: {written} written, {skipped} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
