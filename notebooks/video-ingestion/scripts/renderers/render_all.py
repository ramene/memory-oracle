#!/usr/bin/env python3
"""End-to-end pipeline: pull transcripts from tunafish → run all 4 renderers
→ write into vault. Idempotent + safe to re-run as new transcripts land.

Steps:
  1. rsync tunafish:~/.local/share/nightcode-transcripts/ → local
  2. infer chapter assignments for all transcripts on hand
  3. render per-lesson Obsidian card (full transcript view)
  4. render script-generation prompt + 5-beat outline per lesson
  5. render marketing-copy generation prompt per lesson
  6. regenerate the course _index.md grouping lessons under inferred chapters

Run anytime — fast (no LLM calls, no Deepnote spend). Re-runs only refresh
what changed (or use --force to refresh everything).
"""
from __future__ import annotations
import argparse, json, subprocess, sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

LOCAL_TRANSCRIPTS = Path.home() / ".local/share/nightcode-transcripts"
VAULT_NIGHTCODE   = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/workshops/nightcode"
VAULT_BRAND       = Path.home() / ".remote/@vaults/.build/obsidian-vault/catalog/brand-spine"
VAULT_LESSONS     = VAULT_NIGHTCODE / "lessons"
VAULT_SCRIPTS     = VAULT_BRAND / "nightcode-scripts"
VAULT_MARKETING   = VAULT_BRAND / "nightcode-marketing"
VAULT_META        = VAULT_NIGHTCODE / "_meta"


def run(cmd: list, check: bool = True) -> int:
    print(f"  $ {' '.join(cmd)}")
    return subprocess.run(cmd, check=check).returncode


def pull_transcripts(remote: str) -> None:
    LOCAL_TRANSCRIPTS.mkdir(parents=True, exist_ok=True)
    run(["rsync", "-av",
         f"{remote}:.local/share/nightcode-transcripts/",
         str(LOCAL_TRANSCRIPTS) + "/"])


def render_chapter(force: bool) -> None:
    run([sys.executable, str(SCRIPT_DIR / "infer_chapter_assignment.py"),
         "--input-dir", str(LOCAL_TRANSCRIPTS),
         "--output-dir", str(VAULT_META)])


def render_cards(force: bool) -> None:
    cmd = [sys.executable, str(SCRIPT_DIR / "render_lesson_card.py"),
           "--input-dir", str(LOCAL_TRANSCRIPTS),
           "--output-dir", str(VAULT_LESSONS)]
    if force: cmd.append("--force")
    run(cmd)


def render_scripts(force: bool) -> None:
    cmd = [sys.executable, str(SCRIPT_DIR / "render_lesson_script.py"),
           "--input-dir", str(LOCAL_TRANSCRIPTS),
           "--output-dir", str(VAULT_SCRIPTS)]
    if force: cmd.append("--force")
    run(cmd)


def render_marketing(force: bool) -> None:
    cmd = [sys.executable, str(SCRIPT_DIR / "render_lesson_marketing.py"),
           "--input-dir", str(LOCAL_TRANSCRIPTS),
           "--output-dir", str(VAULT_MARKETING)]
    if force: cmd.append("--force")
    run(cmd)


def render_index() -> None:
    """Regenerate _index.md grouping lessons by inferred chapter."""
    assignments_yaml = VAULT_META / "chapter-assignments.yaml"
    if not assignments_yaml.exists():
        print("  (no chapter assignments yet — skipping _index.md)")
        return

    # Parse the YAML by hand (no PyYAML required)
    lessons_by_ch: dict[str, list[dict]] = {}
    cur = {}
    for line in assignments_yaml.read_text().splitlines():
        s = line.strip()
        if s.startswith("- lesson:"):
            if cur: lessons_by_ch.setdefault(cur.get("chapter", "?"), []).append(cur)
            cur = {"lesson": s.split(":", 1)[1].strip()}
        elif ":" in s and not s.startswith("#"):
            k, v = s.split(":", 1)
            cur[k.strip()] = v.strip()
    if cur:
        lessons_by_ch.setdefault(cur.get("chapter", "?"), []).append(cur)

    chapters_order = [
        ("ch01", "Project setup & component architecture"),
        ("ch02", "UI infrastructure"),
        ("ch03", "Routing & screen layout"),
        ("ch04", "Server, shared, database"),
        ("ch05", "AI chat streaming"),
        ("ch06", "Session management & config"),
        ("ch07", "Tool calling"),
        ("ch08", "User experience & auth"),
        ("ch09", "Billing"),
        ("ch10", "Client-side tool execution"),
        ("ch11", "Packaging & deployment"),
    ]

    out = ["# Nightcode — re-implementation index", ""]
    out.append("> Antonio Erdeljac's pedagogical arc, re-implemented in the operator's voice with operator-owned components.")
    out.append("> Antonio is the structural reference, not the source. See `[[voice-spec]]` for the persona spec.")
    out.append("")
    total = sum(len(v) for v in lessons_by_ch.values())
    out.append(f"**Status:** {total}/41 lessons transcribed · chapter inference auto-run")
    out.append("")
    for ch_id, title in chapters_order:
        out.append(f"## {ch_id} — {title}")
        ls = lessons_by_ch.get(ch_id, [])
        if not ls:
            out.append("- _(no lessons assigned yet — transcripts pending or low-confidence)_")
            out.append("")
            continue
        for l in sorted(ls, key=lambda x: int(x["lesson"][1:])):
            idx = int(l["lesson"][1:])
            link = f"lessons/l{idx:02d}-lesson{idx}.md"
            script_link = f"../../brand-spine/nightcode-scripts/l{idx:02d}-script-prompt.md"
            marketing_link = f"../../brand-spine/nightcode-marketing/l{idx:02d}-marketing-prompt.md"
            out.append(f"- [[{link}|{l['lesson']}]] ({l.get('duration_min','?')} min) · "
                       f"confidence={l.get('confidence','?')} · "
                       f"[script]({script_link}) · [marketing]({marketing_link})")
        out.append("")

    (VAULT_NIGHTCODE / "_index.md").write_text("\n".join(out) + "\n")
    print(f"  ✓ {VAULT_NIGHTCODE / '_index.md'}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--remote", default="tunafish",
                   help="ssh host to rsync transcripts from (default: tunafish)")
    p.add_argument("--skip-pull", action="store_true", help="skip rsync — render from already-local transcripts")
    p.add_argument("--force", action="store_true", help="overwrite existing renders")
    args = p.parse_args(argv)

    print("═══ render_all.py — nightcode pipeline ═══")
    if not args.skip_pull:
        print("\n[1/6] pull transcripts from", args.remote)
        pull_transcripts(args.remote)
    else:
        print("\n[1/6] skip pull (--skip-pull)")
    print("\n[2/6] infer chapter assignments")
    render_chapter(args.force)
    print("\n[3/6] render per-lesson Obsidian cards")
    render_cards(args.force)
    print("\n[4/6] render script-generation prompts + outlines")
    render_scripts(args.force)
    print("\n[5/6] render marketing-copy prompts")
    render_marketing(args.force)
    print("\n[6/6] regenerate course _index.md")
    render_index()
    print("\n✓ done. Vault:", VAULT_NIGHTCODE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
