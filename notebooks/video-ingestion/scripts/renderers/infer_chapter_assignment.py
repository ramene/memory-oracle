#!/usr/bin/env python3
"""Infer which of the 11 upstream chapters each of the 41 nightcode lessons
belongs to, by keyword-matching the Whisper transcript against per-chapter
topic dictionaries derived from the upstream branch names.

Reads transcripts, scores each against 11 chapter dictionaries, writes:
  - <output>/chapter-assignments.yaml   the inferred mapping
  - <output>/chapter-assignments.md     a human-readable rationale

The mapping is then consumed by:
  - render_lesson_card.py (frontmatter `chapter_assignment` field)
  - render_course_index.py (groups lessons under chapters)

Tunable: each chapter has a weighted keyword list + must-have signals.
Score = sum(weight × keyword_frequency_in_transcript / segment_count) per chapter.
The highest-scoring chapter wins, with confidence = top_score / runner_up_score.
"""
from __future__ import annotations
import argparse, json, re, sys
from collections import Counter
from pathlib import Path


DEFAULT_INPUT  = Path.home() / ".local/share/nightcode-transcripts"
DEFAULT_OUTPUT = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/workshops/nightcode/_meta"


# ── Chapter keyword dictionaries ────────────────────────────────────────────
# Weights: 3=strong signal, 2=moderate, 1=weak/contextual.
# These come from the upstream branch names + nightcode README + Phase 2 doc.
CHAPTERS = [
    {
        "id": "ch01",
        "title": "Project setup & component architecture",
        "branch": "01-project-setup-component-architecture",
        "keywords": {
            3: ["bun init", "package.json", "tsconfig", "monorepo", "workspace", "scaffold", "folder structure", "boilerplate", "directory structure"],
            2: ["install", "dependencies", "setup", "create the project", "let's start", "initial", "let's set up"],
            1: ["bun", "pnpm", "npm", "begin", "kick off"],
        },
    },
    {
        "id": "ch02",
        "title": "UI infrastructure (theme, toasts, dialogs, keyboard)",
        "branch": "02-ui-infrastructure",
        "keywords": {
            3: ["theme provider", "toast", "modal", "dialog", "keyboard layer", "sonner", "shadcn", "tailwind", "design tokens"],
            2: ["provider", "context", "wrap the app", "global ui", "react context"],
            1: ["theme", "dark mode", "light mode", "tsx", "component"],
        },
    },
    {
        "id": "ch03",
        "title": "Routing & screen layout",
        "branch": "03-routing-screen-layout",
        "keywords": {
            3: ["router", "screen", "navigation", "layout", "route handler", "page transition", "navigation stack", "url"],
            2: ["screen", "layout", "page", "navigate"],
            1: ["render", "view"],
        },
    },
    {
        "id": "ch04",
        "title": "Server, shared, and database packages",
        "branch": "04-server-shared-database",
        "keywords": {
            3: ["prisma", "schema.prisma", "database", "postgres", "migration", "hono", "trpc", "api route", "server package", "shared package", "monorepo packages"],
            2: ["server", "endpoint", "database", "sql", "schema", "model", "table"],
            1: ["api", "data"],
        },
    },
    {
        "id": "ch05",
        "title": "AI chat streaming",
        "branch": "05-ai-chat-streaming",
        "keywords": {
            3: ["streaming", "stream response", "server-sent events", "sse", "vercel ai sdk", "ai sdk", "chat completion", "chat streaming", "openai stream", "anthropic stream", "use chat", "stream text"],
            2: ["chat", "model", "completion", "tokens", "llm", "claude", "openai", "anthropic"],
            1: ["ai", "agent", "prompt"],
        },
    },
    {
        "id": "ch06",
        "title": "Session management & config",
        "branch": "06-session-management-config",
        "keywords": {
            3: ["session", "session id", "config dialog", "config file", "settings", "user preferences", "persisted state", "local storage"],
            2: ["save", "persist", "config", "configuration", "settings"],
            1: ["state", "store"],
        },
    },
    {
        "id": "ch07",
        "title": "Tool calling",
        "branch": "07-tool-calling",
        "keywords": {
            3: ["tool call", "tool calling", "function call", "function calling", "tool result", "tool definition", "agent tool", "tool use", "execute tool", "tool execution"],
            2: ["execute", "function", "agent", "act on", "perform"],
            1: ["tool"],
        },
    },
    {
        "id": "ch08",
        "title": "User experience & auth",
        "branch": "08-user-experience-auth",
        "keywords": {
            3: ["clerk", "auth", "authentication", "sign in", "sign up", "oauth", "login", "session token", "user account", "auth provider", "@clerk"],
            2: ["user", "account", "login", "logout"],
            1: ["secure"],
        },
    },
    {
        "id": "ch09",
        "title": "Billing",
        "branch": "09-billing",
        "keywords": {
            3: ["polar", "stripe", "billing", "subscription", "credits", "payment", "checkout", "webhook", "purchase", "plan tier", "metering", "@polar"],
            2: ["pay", "cost", "credit", "tier"],
            1: ["money", "charge"],
        },
    },
    {
        "id": "ch10",
        "title": "Client-side tool execution",
        "branch": "10-client-side-tool-execution",
        "keywords": {
            3: ["client-side", "client side", "local tool", "execute locally", "client tool", "browser tool", "shell command", "filesystem", "read file", "write file"],
            2: ["client", "local", "browser"],
            1: ["execute"],
        },
    },
    {
        "id": "ch11",
        "title": "Packaging & deployment (the end)",
        "branch": "11-the-end-packaging",
        "keywords": {
            3: ["bun build", "binary", "executable", "package the cli", "ship it", "release", "deployment", "production", "wrap up", "let's wrap", "we're done", "in conclusion"],
            2: ["build", "compile", "release", "deploy", "publish"],
            1: ["ship", "production"],
        },
    },
]


def score_against_chapter(text: str, chapter: dict) -> dict:
    """Score a transcript against one chapter dictionary.
    Returns {score, matched_terms, must_have_present}."""
    text_lower = text.lower()
    score = 0
    matched = []
    for weight, terms in chapter["keywords"].items():
        for term in terms:
            count = text_lower.count(term.lower())
            if count > 0:
                score += weight * count
                matched.append((term, count, weight))
    return {"score": score, "matched_terms": matched[:10]}


def infer(transcripts_dir: Path, output_dir: Path) -> int:
    transcripts = sorted(transcripts_dir.glob("lesson*-transcript.json"))
    if not transcripts:
        print(f"No transcripts under {transcripts_dir}", file=sys.stderr)
        return 1

    assignments = []
    for tp in transcripts:
        data = json.loads(tp.read_text())
        idx = data["lesson_idx"]
        text = data.get("text", "")
        scores = []
        for ch in CHAPTERS:
            s = score_against_chapter(text, ch)
            scores.append({"chapter": ch["id"], "title": ch["title"], **s})
        scores.sort(key=lambda x: -x["score"])
        top = scores[0]
        runner_up = scores[1] if len(scores) > 1 else {"score": 0}
        confidence = top["score"] / runner_up["score"] if runner_up["score"] > 0 else float("inf")
        assignments.append({
            "lesson_idx": idx,
            "title": data.get("title", f"lesson{idx}"),
            "duration_min": round(data.get("duration_sec", 0) / 60, 1),
            "top_chapter": top["chapter"],
            "top_score": top["score"],
            "runner_up_chapter": runner_up.get("chapter", "?"),
            "runner_up_score": runner_up.get("score", 0),
            "confidence": round(confidence, 2) if confidence != float("inf") else "inf",
            "matched_terms": top["matched_terms"],
        })

    output_dir.mkdir(parents=True, exist_ok=True)
    yaml_path = output_dir / "chapter-assignments.yaml"
    md_path = output_dir / "chapter-assignments.md"

    # YAML — machine-readable
    out = ["# Auto-generated by infer_chapter_assignment.py", "# Edit manually if any assignment looks wrong; downstream renderers honor manual overrides.", ""]
    out.append("assignments:")
    for a in assignments:
        out.append(f"  - lesson: L{a['lesson_idx']:02d}")
        out.append(f"    title: {a['title']}")
        out.append(f"    duration_min: {a['duration_min']}")
        out.append(f"    chapter: {a['top_chapter']}")
        out.append(f"    confidence: {a['confidence']}")
        out.append(f"    runner_up: {a['runner_up_chapter']}")
    yaml_path.write_text("\n".join(out) + "\n")

    # Markdown — human-readable + rationale
    md = ["# Chapter assignments — auto-inferred", ""]
    md.append("Method: keyword-score each transcript against 11-chapter dictionaries derived from upstream branch names. Higher confidence = clearer signal vs runner-up.")
    md.append("")
    md.append("| Lesson | Duration | Chapter (inferred) | Confidence | Runner-up | Top matched terms |")
    md.append("|---|---|---|---|---|---|")
    for a in assignments:
        terms = ", ".join(f"{t[0]}×{t[1]}" for t in a["matched_terms"][:5])
        md.append(f"| L{a['lesson_idx']:02d} | {a['duration_min']} min | {a['top_chapter']} | {a['confidence']} | {a['runner_up_chapter']} | {terms} |")
    md.append("")
    md.append("## Chapter rollups")
    md.append("")
    by_chapter = {}
    for a in assignments:
        by_chapter.setdefault(a["top_chapter"], []).append(a["lesson_idx"])
    for ch in CHAPTERS:
        ls = sorted(by_chapter.get(ch["id"], []))
        md.append(f"- **{ch['id']}** ({ch['title']}): {ls if ls else '_(no transcripts assigned yet)_'}")
    md_path.write_text("\n".join(md) + "\n")

    print(f"✓ {yaml_path}  ({yaml_path.stat().st_size} bytes)")
    print(f"✓ {md_path}    ({md_path.stat().st_size} bytes)")
    print(f"  inferred for {len(assignments)} lesson(s)")
    return 0


def load_chapter_dict_yaml(path: Path) -> list[dict]:
    """Load a per-course chapter dictionary from YAML (produced by derive_chapter_dict.py).
    Replaces the hardcoded CHAPTERS list when --dict is passed."""
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML required for --dict; pip install pyyaml")
    data = yaml.safe_load(path.read_text())
    out = []
    for ch in data.get("chapters", []):
        # Normalize keyword dict keys to ints
        kw = {int(k): v for k, v in (ch.get("keywords") or {}).items()}
        out.append({
            "id": ch["id"],
            "title": ch.get("title", ch["id"]),
            "branch": ch.get("branch"),
            "keywords": kw,
        })
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input-dir",  type=Path, default=DEFAULT_INPUT)
    p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument("--dict", type=Path, default=None,
                   help="path to a per-course chapter-dict YAML (overrides built-in nightcode CHAPTERS)")
    args = p.parse_args(argv)

    # If --dict given, swap the module-level CHAPTERS in-place
    if args.dict:
        global CHAPTERS
        CHAPTERS = load_chapter_dict_yaml(args.dict)
    return infer(args.input_dir, args.output_dir)


if __name__ == "__main__":
    sys.exit(main())
