#!/usr/bin/env python3
"""Render a per-lesson SHOOTABLE SCRIPT from Whisper transcript + voice-spec.

Two outputs per lesson:
  1. <slug>-script-prompt.md   — Claude/LLM-ready prompt that produces the final script.
                                  Embeds: Antonio's full transcript, the voice-spec,
                                  the MikoAI Script Generator framework (5 beats,
                                  Life-Force-8, T-D-A), and lesson-specific structure.
  2. <slug>-script-outline.md  — pre-filled 5-beat outline that anchors the LLM (or
                                  the operator, if filling manually) to extracted source.

The prompt is provider-agnostic — paste into Claude, GPT, local Ollama on tunafish,
or wherever. Renderer never makes an LLM call itself; zero autonomous spend.

Where TODO fields remain in voice-spec.yaml, the renderer leaves
`<TODO from voice-spec>` placeholders rather than guessing.
"""
from __future__ import annotations
import argparse, json, re, sys
from pathlib import Path

# yaml is in stdlib? no — use a tiny dependency-free parser for our flat spec
try:
    import yaml
except ImportError:
    yaml = None


DEFAULT_INPUT       = Path.home() / ".local/share/nightcode-transcripts"


# ─────────────────────────────────────────────────────────────────────────────
# HVR retention skeleton (Paul Hilse's HVR Method). Course IP — no repo file,
# so inlined as a constant (mirrors how the MikoAI summary used to be inlined).
# Optional --hvr-file overrides this; defaults to None → this constant.
# ─────────────────────────────────────────────────────────────────────────────
HVR_METHOD = """\
INTRO (Most Vital 30 sec — the highest-leverage part of the video):
  - HOOK: 1 sentence, interesting or shocking.
  - WHAT: 2-3 sentences. Tease + expand the title. Summarize, but DON'T give
    it all away (a full giveaway makes viewers click off).
  - WHY: 1-2 sentences. Tell them why to stay till the end (retention promise).
  - DO NOT ask for subscribe / notifications up front. Earned by value, not begged for.
BODY (follow loosely):
  - TEASE CLIMAX: re-excite them.
  - INFO: deliver value on the topic. Cut ALL fluff — fluff kills retention.
  - CLIMAX: deliver on the promise the title made.
  - (List content: count DOWN 10 -> 1, most interesting item first.)
CONCLUSION:
  - RECAP: 1-3 sentences, the info made digestible.
  - ABRUPT END: end before the viewer expects it — no long outro.
GLOBAL: third-person narration (no 'I' / 'my opinion'); plain words (no
  over-complicated vocabulary); only accurate info; aim for the medium length below."""

HVR_BLACKLIST = """\
HVR blacklist (subtractive — these override every other layer):
  - Never use the word "article" (these become videos; "in this article" reads wrong on camera).
  - No curse words.
  - No politics — keep political beliefs out of the script.
  - Never attack a person / celebrity / character."""

def _resolve_voice_spec() -> Path:
    """Prefer voice-spec-alternative.yaml (operator's filled-in brand voice);
    fall back to voice-spec.yaml (the MikoAI template with TODOs)."""
    base = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/brand-spine/avatar"
    alt = base / "voice-spec-alternative.yaml"
    canonical = base / "voice-spec.yaml"
    return alt if alt.exists() else canonical

DEFAULT_VOICE_SPEC  = _resolve_voice_spec()
DEFAULT_OUTPUT      = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/brand-spine/nightcode-scripts"
DEFAULT_MIKOAI      = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/_meta/mikoai-frameworks"


def load_voice_spec(path: Path) -> dict:
    """Load voice-spec.yaml. If yaml lib unavailable, return raw text and
    mark all fields as unparsed — renderer will emit placeholders."""
    if not path.exists():
        return {"_error": f"voice-spec not found at {path}", "_raw": ""}
    raw = path.read_text()
    if yaml is None:
        return {"_error": "PyYAML not installed; pip install pyyaml. Raw spec embedded.", "_raw": raw}
    try:
        return yaml.safe_load(raw) or {}
    except Exception as e:
        return {"_error": f"YAML parse failed: {e}", "_raw": raw}


def todo_or(value, fallback: str = "<TODO from voice-spec>") -> str:
    """Return value if non-TODO, else placeholder."""
    if value is None or value == "TODO" or (isinstance(value, str) and value.strip().upper() == "TODO"):
        return fallback
    if isinstance(value, list):
        return ", ".join(str(v) for v in value) if value else fallback
    return str(value)


# Forbidden words enforced by the lint pass (the in-prompt hard-no gate is only
# advisory). Mirrors voice-spec voice.forbidden_words + the HVR blacklist word.
FORBIDDEN_WORDS = [
    "synergy", "leverage", "10x", "frictionless", "best-in-class",
    "next-generation", "transformative", "game-changing", "disruptive",
    "seamless",
]
HVR_FORBIDDEN_WORDS = ["article"]  # HVR blacklist — "in this article" reads wrong on camera


def lint_forbidden(text: str, extra: list[str] | None = None) -> list[tuple[str, int]]:
    """Greps generated-script TEXT for forbidden words (voice-spec + HVR 'article').
    Returns a list of (word, count) for every word that appears at least once.
    Whole-word, case-insensitive. Real enforcement vs the advisory in-prompt gate."""
    words = list(FORBIDDEN_WORDS) + list(HVR_FORBIDDEN_WORDS) + list(extra or [])
    hits: list[tuple[str, int]] = []
    for w in words:
        n = len(re.findall(rf"\b{re.escape(w)}\b", text, flags=re.IGNORECASE))
        if n:
            hits.append((w, n))
    return hits


def _load_mikoai(mikoai_dir: Path) -> dict:
    """Activate the previously-unused mikoai_dir param: load the 5 framework
    files (5-beat / T-D-A / Mental Movies / LF8 / CLARCCS) from the 27-file dir
    and TRIM each to its essential rules (full files = prompt bloat, esp. for
    Ollama on tunafish). Missing/unreadable file → '' (graceful degrade)."""
    files = {
        "five_beat":      "05-Copywriting--11-The Emotional Journey Framework.txt",
        "tda":            "05-Copywriting--03-The Tension-Desire-Action Formula.txt",
        "mental_movies":  "05-Copywriting--04-Mental Movies- The Secret to Scripts That Feel Real.txt",
        "lf8":            "05-Copywriting--02-The Life-Force 8- What Humans Actually Want.txt",
        "clarccs":        "05-Copywriting--09-The Six Psychological Triggers CLARCCS.txt",
    }
    out: dict[str, str] = {}
    for key, fname in files.items():
        try:
            raw = (Path(mikoai_dir) / fname).read_text()
        except Exception:
            out[key] = ""
            continue
        out[key] = _trim_framework(key, raw)
    return out


def _trim_framework(key: str, raw: str) -> str:
    """Collapse a framework .txt to its load-bearing rules (a few lines), so the
    prompt stays lean. Falls back to a length-capped excerpt if the heuristic
    finds nothing useful."""
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    keep: list[str] = []
    if key == "five_beat":
        for ln in lines:
            if re.match(r"^Beat\s*[1-5]:", ln):
                keep.append("- " + ln)
    elif key == "tda":
        keep = [
            "- Tension -> Desire -> Action. Hook calls out/creates TENSION;",
            "  body speaks to the DESIRE for relief; close points to ACTION.",
            "- Don't skip tension: no tension -> no desire -> no action. Make them FEEL it, don't just describe it.",
        ]
    elif key == "mental_movies":
        keep = [
            "- Specific visual words install images involuntarily. Vague language draws a blank.",
            "- Replace 'you'll feel better' with a concrete scene the viewer can SEE (and almost smell).",
            "- For every line ask: can the viewer SEE this? If no, rewrite with sensory specifics.",
        ]
    elif key == "lf8":
        keep = [
            "- Life-Force 8 (biological, always-on desires): survival/life-enjoyment/life-extension;",
            "  food & drink; freedom from fear/pain/danger; sexual companionship; comfortable living;",
            "  superiority/winning; care & protection of loved ones; social approval.",
            "- Don't NAME the desire — paint a picture that activates it. Tap the 2-3 that fit the audience.",
        ]
    elif key == "clarccs":
        keep = [
            "- CLARCCS (Cialdini): Comparison/social-proof, Liking, Authority, Reciprocity,",
            "  Commitment/Consistency, Scarcity.",
            "- Authority = specificity of insight, not credentials. Reciprocity = free value before any ask.",
            "- Build them naturally over the script; never stuff all six in.",
        ]
    body = "\n".join(keep).strip()
    if not body:
        # graceful fallback: first ~600 chars of the raw file
        body = raw.strip()[:600]
    return body


def first_n_segments_text(segments: list[dict], n: int = 5) -> str:
    return " ".join(s["text"].strip() for s in segments[:n])


def last_n_segments_text(segments: list[dict], n: int = 3) -> str:
    return " ".join(s["text"].strip() for s in segments[-n:])


def detect_script_type(transcript: dict) -> str:
    """Heuristic: pick a MikoAI script type that best fits the lesson.
    Coding tutorials lean Problem-Solution or Pattern Interrupt — concrete pain
    + actionable reframe. Manifesto-style lessons (L01) lean Story-Based."""
    dur = transcript.get("duration_sec", 0)
    text = transcript.get("text", "").lower()
    # Manifesto / intro signals
    if any(s in text for s in ("welcome to", "let me explain what", "couldn't be more excited")):
        return "Story-Based"
    if dur < 180:  # short = pattern-interrupt territory
        return "Pattern Interrupt"
    if "let's" in text and ("install" in text or "set up" in text or "create" in text):
        return "Problem-Solution"
    return "Problem-Solution"  # default


def render_prompt(transcript: dict, spec: dict, mikoai_dir: Path,
                  hvr_method: str | None = None) -> str:
    """Emit the LLM-ready prompt. Self-contained; provider-agnostic.

    v2: layered HVR -> 5-beat -> Voice -> Hooks -> Hard-No template. The
    mikoai_dir param (previously received but unused) is now activated via
    _load_mikoai(); hvr_method overrides the inlined HVR_METHOD constant
    (None -> constant). Still ZERO LLM/network calls; same two .md outputs."""
    idx = transcript["lesson_idx"]
    text = transcript.get("text", "")
    duration = transcript.get("duration_sec", 0)
    segments = transcript.get("segments", [])
    script_type = detect_script_type(transcript)

    # Live MikoAI frameworks (activates the previously-unused mikoai_dir param).
    miko = _load_mikoai(mikoai_dir)
    hvr = (hvr_method or HVR_METHOD)

    # Voice-spec extraction (with TODO fallbacks)
    persona = spec.get("persona", {}) if isinstance(spec, dict) else {}
    voice = persona.get("voice", {}) if isinstance(persona, dict) else {}
    niche = spec.get("niche", {}) if isinstance(spec, dict) else {}
    lf8 = spec.get("life_force_8_emphasis", {}) if isinstance(spec, dict) else {}
    constraints = spec.get("script_constraints", {}) if isinstance(spec, dict) else {}
    clarccs = spec.get("clarccs_emphasis", {}) if isinstance(spec, dict) else {}
    grounding = spec.get("voice_grounding", {}) if isinstance(spec, dict) else {}

    # New voice-spec fields v1 dropped (all via todo_or → graceful placeholders).
    swears = todo_or(voice.get("swears"))
    clarccs_triggers = todo_or(clarccs.get("triggers"))
    hard_no_list = todo_or(grounding.get("hard_no_list"))
    opening_hook_pattern = todo_or(constraints.get("opening_hook_pattern"))
    closing_cta_pattern = todo_or(constraints.get("closing_cta_pattern"))

    # brand_commitments is a list of single-key dicts (e.g. `- no_clickbait_hooks: true`).
    # Flatten to "key=value" pairs so it embeds cleanly; degrade via todo_or.
    bc_raw = spec.get("brand_commitments") if isinstance(spec, dict) else None
    if isinstance(bc_raw, list):
        bc_pairs = []
        for item in bc_raw:
            if isinstance(item, dict):
                bc_pairs.extend(f"{k}={v}" for k, v in item.items())
            else:
                bc_pairs.append(str(item))
        brand_commitments = todo_or(bc_pairs)
    else:
        brand_commitments = todo_or(bc_raw)

    target_length = (constraints.get("default_length", {}) or {}).get("medium_form", "5-8 min")

    prompt = f"""# Lesson {idx} — Script Generation Prompt (v2: HVR → 5-beat → Voice → Hooks → Hard-No)

> Paste this entire document into Claude, GPT-4o, Ollama on tunafish, or any
> capable LLM. The LLM has everything it needs: Antonio's full transcript, your
> voice-spec, the HVR retention skeleton, the MikoAI Script Generator framework
> (5 beats, Life-Force-8, T-D-A, Mental Movies, CLARCCS), and a final hard-no
> compliance gate.
>
> No autonomous LLM calls from this renderer — you control when/where the
> generation happens.

---

## 0. How to read this prompt (layer order is load-bearing)

Compose by applying FIVE layers IN ORDER. Each later layer is a constraint over
the output of the earlier ones. Do not let a later layer rewrite the macro
structure of an earlier one.
  LAYER 1 — HVR retention skeleton (macro shape)
  LAYER 2 — MikoAI 5-beat Emotional Journey (mapped ONTO HVR)
  LAYER 3 — Lachlan Dai voice constraints (HOW every line sounds)
  LAYER 4 — MikoAI LF8 + CLARCCS hooks (WHY they keep watching/act)
  LAYER 5 — Hard-No compliance gate (final pass: delete/rewrite any violation)

## 1. Your role (LLM system prompt)

You are an expert YouTube scriptwriter who has internalized BOTH Paul Hilse's
**HVR Method** (faceless long-form retention) and the **MikoAI Script Generator
framework** (Life-Force-8 + Tension-Desire-Action + Mental Movies + CLARCCS +
5-beat Emotional Journey). You are writing for a coding-tutorial niche
(specifically: Verum-gated multi-LLM coding agents) using the operator's
voice-spec below.

You are re-implementing Antonio Erdeljac's nightcode lesson {idx} (a workshop
called "Build Your Own Cloud Code") in the operator's own brand voice. You are
NOT copying his content. You are using his pedagogical arc as a structural
reference and producing original content that delivers the same teaching value
in the operator's voice for the operator's audience.

## 2. LAYER 1 — HVR Method — macro RETENTION skeleton (build the spine first)

{hvr}

{HVR_BLACKLIST}

## 3. LAYER 2 — MikoAI 5-beat mapped ONTO the HVR skeleton

**Script type for this lesson:** {script_type}

Map the 5 beats onto the HVR slots so structure (HVR) and emotion (5-beat) reinforce:
- HVR HOOK + WHAT + WHY  ⟶  Beat 1 Recognition + Beat 2 Understanding
- HVR TEASE CLIMAX        ⟶  Beat 3 Hope (pain → possibility)
- HVR INFO + CLIMAX       ⟶  Beat 4 Insight (the meat / reframe)
- HVR RECAP + ABRUPT END  ⟶  Beat 5 Empowerment (close on capability)

5-beat emotional journey (use all 5 unless the lesson is < 90 sec):
{miko['five_beat']}

Tension-Desire-Action: HOOK creates TENSION (specific/sensory); body speaks to
the DESIRE for relief; close points to ACTION (subscribe / build it / book a call).
{miko['tda']}

Mental Movies: concrete visual language, never vague — install images in the viewer's mind.
{miko['mental_movies']}

Feature-Benefit Test: after every piece of wisdom, ask "so what does this DO for them?" and say THAT.

## 4. LAYER 3 — Lachlan Dai voice (apply to EVERY line; do NOT change structure)

```yaml
persona:
  name:                 {todo_or(persona.get('name'))}
  archetype:            {todo_or(persona.get('archetype'))}
  visual:               {todo_or(persona.get('visual'))}
  voice_pace:           {todo_or(voice.get('pace'))}
  voice_cadence:        {todo_or(voice.get('cadence'))}
  voice_vocabulary:     {todo_or(voice.get('vocabulary'))}
  catchphrases:         {todo_or(voice.get('catchphrases'))}
  forbidden_words:      {todo_or(voice.get('forbidden_words'))}
  attitude_toward_antonio: {todo_or(persona.get('attitude_toward_antonio'))}

niche:
  primary:              {todo_or(niche.get('primary'))}
  sub_niche:            {todo_or(niche.get('sub_niche'))}
  target_audience:      {todo_or(niche.get('target_audience'))}
  audience_pain_phrases:{todo_or(lf8.get('audience_pain_phrases'))}

life_force_8 priorities:
  primary:              {todo_or(lf8.get('primary'))}
  secondary:            {todo_or(lf8.get('secondary'))}
  tertiary:             {todo_or(lf8.get('tertiary'))}
```

PACE {todo_or(voice.get('pace'))} · CADENCE {todo_or(voice.get('cadence'))} · VOCAB {todo_or(voice.get('vocabulary'))} · swears {swears}.
Weave catchphrases naturally — **≤2 per script**, land the CLIMAX/close on one.
Operator-practitioner POV (receipts, real substrate), not generic AI-influencer.
Reconcile HVR third-person narration with the operator stance: authoritative
practitioner, no chatty 'in my opinion' filler. Attitude toward Antonio:
{todo_or(persona.get('attitude_toward_antonio'))}. Use OUR vendor matrix
substitutes, never Antonio's exact stack.
Opening-hook pattern: {opening_hook_pattern}
Closing-CTA pattern: {closing_cta_pattern}

## 5. LAYER 4 — LF8 + CLARCCS (after voice, so persuasion rides the operator's tone)

LF8 anchors (tap 1-2, NEVER name them — paint pictures):
  primary={todo_or(lf8.get('primary'))}  secondary={todo_or(lf8.get('secondary'))}  tertiary={todo_or(lf8.get('tertiary'))}
{miko['lf8']}

Mirror these audience pain phrases in Beats 1-2: {todo_or(lf8.get('audience_pain_phrases'))}

CLARCCS (build naturally, don't stuff all six): {clarccs_triggers}
Authority = insight + receipts, not credentials; Comparison = real success/failure; Consistency = same principles across years.
{miko['clarccs']}

## 6. LAYER 5 — HARD-NO gate (FINAL pass — wins over every layer above)

Forbidden words (zero tolerance — scan + remove): {todo_or(voice.get('forbidden_words'))}
{HVR_BLACKLIST}
Brand commitments (never violate): {brand_commitments}
Persona hard-no list: {hard_no_list}
Attribution: {todo_or(persona.get('attitude_toward_antonio'))}
If a forbidden word is the natural choice, replace it with something concrete —
describe the change, don't label it.

## 7. Antonio's source material (Lesson {idx})

**Duration:** {duration/60:.1f} min  ·  **Segments:** {len(segments)}  ·  **Words:** {len(text.split())}

**Opening (first 60 sec — captures Antonio's hook for this lesson):**

> {first_n_segments_text(segments, 5)}

**Closing (last 30 sec — captures Antonio's CTA/payoff):**

> {last_n_segments_text(segments, 3)}

**Full transcript with timestamps:**

```
{chr(10).join(f'[{s["start"]:6.1f}s] {s["text"].strip()}' for s in segments)}
```

## 8. Output format

Produce a SHOOTABLE SCRIPT with this exact structure:

```
[SCRIPT TYPE: {script_type}]
[TARGET LENGTH: {target_length}]
[LIFE-FORCE 8 ANCHORS: <from voice-spec>]
[ANTONIO ATTRIBUTION POSITION: <e.g., "ack at 0:15, then independent re-implementation">]

[HVR INTRO — HOOK 0:00-0:08, must stop the scroll]
"<the line you'd say on camera>"
[VISUAL: <what's on screen>]
[TENSION NOTE: <what desire you're calling out>]

[HVR WHAT+WHY / BEAT 1+2 — Recognition + Understanding — 0:08-1:15]
"<lines>"
[VISUAL: <what's on screen>]

[HVR TEASE CLIMAX / BEAT 3 — Hope — 1:15-1:45]
"<lines>"
[VISUAL: ...]

[HVR INFO+CLIMAX / BEAT 4 — Insight — 1:45-4:30] (the meat of the lesson — code walkthrough goes here)
"<lines>"
[CODE ON SCREEN: <which file/snippet — OUR vendor substitutes, not Antonio's exact stack>]
[VOICEOVER: <what to say while screen-recording the code>]

[HVR RECAP+ABRUPT END / BEAT 5 — Empowerment — 4:30-5:00] (land on a catchphrase)
"<lines>"
[CTA: <from voice-spec>]
[VISUAL: <closing card>]
```

After the script, append:
- **3 alternative HOOK lines** (LLM-generated variants targeting different Life-Force-8 anchors)
- **3 thumbnail-friendly KEY LINES** (the lines that could be a video title or thumbnail caption)
- **Production notes** (B-roll, lower-thirds, transitions, music cues)
- **Compliance self-check** (0 forbidden words, 0 HVR-blacklist, ≤2 catchphrases, hard-no clean)
- **Common-pitfall warnings** for the operator while shooting (don't read like the transcript; don't mention Antonio's specific code paths; use OUR vendor matrix's substitutes — NextAuth not Clerk, Stripe not Polar, etc.)

Now generate the script.
"""

    return prompt


def render_outline(transcript: dict, spec: dict) -> str:
    """A skeleton outline that you (or the LLM) can fill against the transcript.
    Useful even without an LLM pass — gives operator a structural starting point."""
    idx = transcript["lesson_idx"]
    duration = transcript.get("duration_sec", 0)
    segments = transcript.get("segments", [])
    script_type = detect_script_type(transcript)

    # Slice the transcript into 5 rough beats by time
    if duration > 0 and segments:
        beat_size = duration / 5
        beats = [[] for _ in range(5)]
        for s in segments:
            i = min(4, int(s["start"] / beat_size))
            beats[i].append(s)
    else:
        beats = [segments]

    out = [f"# Lesson {idx} — Script Outline ({script_type})\n"]
    out.append(f"> Duration anchor: {duration/60:.1f} min  ·  Script type: {script_type}\n")
    out.append(f"> Voice-spec at `brand-spine/avatar/voice-spec.yaml` — fill TODOs before rendering final script\n\n")

    beat_titles = [
        "1. Recognition (I See You)",
        "2. Understanding (I Get It)",
        "3. Hope (There's a Way)",
        "4. Insight (Here's How)",
        "5. Empowerment (You Can Do This)",
    ]
    for title, beat_segs in zip(beat_titles, beats):
        out.append(f"## {title}\n")
        if not beat_segs:
            out.append("_(no segments in this time slice — generate from voice-spec)_\n")
            continue
        out.append(f"**Antonio's words in this slice ({beat_segs[0]['start']:.0f}-{beat_segs[-1]['end']:.0f}s):**\n\n")
        out.append("> " + " ".join(s["text"].strip() for s in beat_segs) + "\n\n")
        out.append("**Your re-implementation (fill in):**\n\n")
        out.append("- HOOK: `<line>`\n")
        out.append("- VISUAL: `<screen>`\n")
        out.append("- LIFE-FORCE-8 tap: `<which desire>`\n\n")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT)
    p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument("--voice-spec", type=Path, default=DEFAULT_VOICE_SPEC)
    p.add_argument("--mikoai-dir", type=Path, default=DEFAULT_MIKOAI)
    p.add_argument("--hvr-file", type=Path, default=None,
                   help="optional file overriding the inlined HVR_METHOD constant")
    p.add_argument("--only", type=int, nargs="*")
    p.add_argument("--force", action="store_true")
    p.add_argument("--lint", type=Path, default=None,
                   help="lint a generated script file for forbidden words + HVR 'article'; "
                        "exits non-zero on any hit. Does NOT render.")
    args = p.parse_args(argv)

    # --lint mode: real enforcement of the hard-no gate on an already-generated
    # script. Standalone — renders nothing, makes no LLM call.
    if args.lint is not None:
        if not args.lint.exists():
            print(f"--lint: file not found: {args.lint}", file=sys.stderr)
            return 2
        hits = lint_forbidden(args.lint.read_text())
        if hits:
            print(f"  ✗ {args.lint.name}: forbidden words found:", file=sys.stderr)
            for w, n in hits:
                print(f"      {w!r} x{n}", file=sys.stderr)
            return 1
        print(f"  ✓ {args.lint.name}: clean (0 forbidden words)")
        return 0

    # Resolve optional HVR override file once (None → HVR_METHOD constant).
    hvr_override = None
    if args.hvr_file is not None:
        try:
            hvr_override = args.hvr_file.read_text()
        except Exception as e:
            print(f"  ⚠️  --hvr-file unreadable ({e}); using inlined HVR_METHOD", file=sys.stderr)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    spec = load_voice_spec(args.voice_spec)
    if "_error" in spec:
        print(f"  ⚠️  voice-spec issue: {spec['_error']}", file=sys.stderr)

    transcripts = sorted(args.input_dir.glob("lesson*-transcript.json"))
    if args.only:
        transcripts = [t for t in transcripts if int(re.search(r"lesson(\d+)", t.name).group(1)) in args.only]
    if not transcripts:
        print(f"No transcripts under {args.input_dir}", file=sys.stderr)
        return 1

    written = skipped = 0
    for tp in transcripts:
        data = json.loads(tp.read_text())
        idx = data["lesson_idx"]
        prompt_path = args.output_dir / f"l{idx:02d}-script-prompt.md"
        outline_path = args.output_dir / f"l{idx:02d}-script-outline.md"
        if prompt_path.exists() and outline_path.exists() and not args.force:
            print(f"  L{idx:02d}  skip (use --force to overwrite)")
            skipped += 1
            continue
        prompt_path.write_text(render_prompt(data, spec, args.mikoai_dir, hvr_override))
        outline_path.write_text(render_outline(data, spec))
        print(f"  L{idx:02d}  ✓ wrote prompt ({prompt_path.stat().st_size//1024} KB) + outline ({outline_path.stat().st_size//1024} KB)")
        written += 1

    print(f"\nSummary: {written} written, {skipped} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
