#!/usr/bin/env python3
"""Render a per-lesson Obsidian card from a Whisper transcript JSON.

Input:  ~/.local/share/nightcode-transcripts/lessonXX-transcript.json
Output: ~/.remote/@vaults/.build/obsidian-vault/catalog/workshops/nightcode/lessons/lXX-<slug>.md

The card surfaces Antonio's full narration + code snippets + structured signal
so the operator can see the actual extraction depth (vs the thin chapter rollups
Agent 4 emitted in Phase 3e).

Per-chapter mapping is hard-coded from the upstream branch list (11 chapters):
  ch01 (project-setup):              L01-L05?
  ch02 (ui-infrastructure):          L06-L08?
  ch03 (routing-screen-layout):      L09-L11?
  ch04 (server-shared-database):     L12-L15?
  ch05 (ai-chat-streaming):          L16-L20?
  ch06 (session-management-config):  L21-L24?
  ch07 (tool-calling):               L25-L29?
  ch08 (user-experience-auth):       L30-L33?
  ch09 (billing):                    L34-L37?
  ch10 (client-side-tool-execution): L38-L40?
  ch11 (the-end-packaging):          L41

The exact L→ch mapping needs operator confirmation once we have transcripts.
For now, this script writes a draft and tags the card so we can curate later.
"""
from __future__ import annotations
import argparse, json, re, sys
from pathlib import Path

DEFAULT_INPUT  = Path.home() / ".local/share/nightcode-transcripts"
DEFAULT_OUTPUT = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/workshops/nightcode/lessons"


# Heuristic: detect code from transcript segments using common shell/code patterns.
# Coding tutorials interleave narration with literal code recital ("npm install ...",
# "const foo equals ...", etc.). Surface these as candidate snippets in the card.
CODE_HINTS = re.compile(
    r"(npm install|pnpm add|bun add|yarn add|"
    r"import \w+|require\(|export (const|default|function|class)|"
    r"function \w+\(|const \w+ ?=|let \w+ ?=|"
    r"\.tsx?\b|\.json\b|package\.json|"
    r"useState|useEffect|return \(|"
    r"```|\$\s+\w)",
    re.IGNORECASE,
)


def slugify(s: str) -> str:
    s = s.lower().strip()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")[:60]


def candidate_code_segments(segments: list[dict]) -> list[dict]:
    return [s for s in segments if CODE_HINTS.search(s.get("text", ""))]


def first_minute_summary(segments: list[dict]) -> str:
    """Antonio's opening — typically sets up what the lesson teaches.
    Pull all text from the first ~60 sec for an at-a-glance hook."""
    out = []
    for s in segments:
        if s.get("end", 0) > 60:
            break
        out.append(s.get("text", "").strip())
    return " ".join(out).strip()


def render_card(transcript: dict, stub: str = "nightcode") -> str:
    idx = transcript["lesson_idx"]
    text = transcript.get("text", "").strip()
    segments = transcript.get("segments", [])
    duration = transcript.get("duration_sec", 0)
    language = transcript.get("language", "?")
    throughput = transcript.get("throughput_realtime_x", 0)

    opening = first_minute_summary(segments)
    code_hits = candidate_code_segments(segments)
    chars = len(text)
    words = len(text.split())

    frontmatter = (
        "---\n"
        f"lesson: L{idx:02d}\n"
        f"title: lesson{idx}\n"
        f"chapter_assignment: pending\n"
        f"duration_sec: {duration:.1f}\n"
        f"duration_min: {duration/60:.1f}\n"
        f"language: {language}\n"
        f"transcript_chars: {chars}\n"
        f"transcript_words: {words}\n"
        f"segment_count: {len(segments)}\n"
        f"code_hint_segments: {len(code_hits)}\n"
        f"source_file: {transcript.get('source_file', '?')}\n"
        f"model: {transcript.get('model', '?')}\n"
        f"throughput: {throughput}x realtime\n"
        f"tags:\n"
        f"  - catalog\n"
        f"  - workshop\n"
        f"  - {stub}\n"
        f"  - lesson\n"
        f"  - antonio-source\n"
        "---\n\n"
    )

    body = [f"# Lesson {idx} — Antonio's narration\n"]
    body.append(f"> Source: `{transcript.get('source_file','?')}`  ·  "
                f"{duration/60:.1f} min  ·  {words} words  ·  {len(segments)} segments  ·  "
                f"transcribed at {throughput}× realtime\n")

    if opening:
        body.append("## Opening (first 60 seconds — the hook)\n")
        body.append(opening + "\n")

    if code_hits:
        body.append(f"\n## Candidate code recitals ({len(code_hits)} segments)\n")
        body.append("> Heuristic match — segments that read like code or shell commands. Cross-check with the upstream branch's source.\n\n")
        for s in code_hits[:20]:
            body.append(f"- `[{s['start']:.1f}s]` {s['text'].strip()}")
        if len(code_hits) > 20:
            body.append(f"- ... ({len(code_hits) - 20} more — see full transcript below)\n")

    body.append("\n## Full transcript with timestamps\n")
    body.append("```\n")
    for s in segments:
        body.append(f"[{s['start']:6.1f}s → {s['end']:6.1f}s]  {s['text'].strip()}")
    body.append("```\n")

    return frontmatter + "\n".join(body)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input-dir",  type=Path, default=DEFAULT_INPUT,
                   help=f"transcripts dir (default: {DEFAULT_INPUT})")
    p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT,
                   help=f"per-lesson Obsidian cards dir (default: {DEFAULT_OUTPUT})")
    p.add_argument("--only", type=int, nargs="*",
                   help="restrict to specific lesson indices (e.g. --only 1 2 5)")
    p.add_argument("--force", action="store_true",
                   help="overwrite existing cards")
    p.add_argument("--stub", default="nightcode",
                   help="workshop stub tag for the card frontmatter (default: nightcode)")
    args = p.parse_args(argv)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    transcripts = sorted(args.input_dir.glob("lesson*-transcript.json"))
    if args.only:
        transcripts = [t for t in transcripts if int(re.search(r"lesson(\d+)", t.name).group(1)) in args.only]
    if not transcripts:
        print(f"No transcripts under {args.input_dir}", file=sys.stderr)
        return 1

    written = skipped = errored = 0
    for tp in transcripts:
        try:
            data = json.loads(tp.read_text())
            idx = data["lesson_idx"]
            out = args.output_dir / f"l{idx:02d}-lesson{idx}.md"
            if out.exists() and not args.force:
                print(f"  L{idx:02d}  skip (use --force to overwrite)")
                skipped += 1
                continue
            out.write_text(render_card(data, args.stub))
            print(f"  L{idx:02d}  ✓ wrote {out.name} ({out.stat().st_size//1024} KB)")
            written += 1
        except Exception as e:
            print(f"  ✗ {tp.name}: {type(e).__name__}: {e}", file=sys.stderr)
            errored += 1

    print(f"\nSummary: {written} written, {skipped} skipped, {errored} errored")
    return 0 if errored == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
