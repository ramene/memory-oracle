#!/usr/bin/env python3
"""
Drop batch_ingest extraction outputs into the operator's Obsidian vault as
curated markdown — one .md per video, full label preserved in frontmatter +
title, rich extraction sections for refinement.

Design:
  The manifest is the SINGLE SOURCE OF TRUTH for full_label, source_type,
  module/lesson structure, and any source-specific metadata.  The batch_ingest
  output.json is the SINGLE SOURCE OF TRUTH for extracted signal.  This
  script joins them on `short_id` and emits markdown that surfaces both for
  operator review.

Output location:
  ~/Journal/courses/<root-label>/
    manifest.md                  index of all lessons
    <full-label>.md              one per video
                                 — frontmatter carries short_id, mp4_path,
                                   output_json_path, source_type, full_label,
                                   module/lesson, source_metadata
                                 — body sections: extraction signal lifted
                                   from output.json (segment_summary,
                                   key_quotes, code_snippets, …)
                                 — curation slots flagged with TODO

Usage:
  ./extraction_to_obsidian.py --manifest <path/to/manifest.json> \\
                              [--vault-root ~/Journal/courses]

  ./extraction_to_obsidian.py --manifest ~/Downloads/upload/build-and-deploy-a-cursor-clone-manifest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

VAULT_ROOT_DEFAULT = Path.home() / "Journal" / "courses"
UPLOAD_DIR = Path.home() / "Downloads" / "upload"


# ─── helpers ────────────────────────────────────────────────────────────────

def short_id_from_label(label: str, length: int = 11) -> str:
    return hashlib.sha1(label.encode("utf-8")).hexdigest()[:length]


def first_signal(chunks: list, key: str):
    for c in chunks:
        v = (c.get("signal") or {}).get(key)
        if isinstance(v, list) and v:
            return v
        if isinstance(v, str) and v.strip():
            return v
        if isinstance(v, dict) and v:
            return v
    return None


def collect_signal(chunks: list, key: str) -> list:
    out = []
    for c in chunks:
        v = (c.get("signal") or {}).get(key)
        if isinstance(v, list):
            out.extend(v)
        elif isinstance(v, str) and v.strip():
            out.append(v)
    return out


def yaml_quote(s) -> str:
    """Quote a value for safe YAML frontmatter."""
    if s is None:
        return "null"
    if isinstance(s, bool):
        return "true" if s else "false"
    if isinstance(s, (int, float)):
        return str(s)
    s = str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{s}"'


def md_quote_block(label: str, items: list, key_extractor=None) -> str:
    """Render a list as a markdown bullet section. `key_extractor` pulls
    the printable string from each item (handles dict|str|other)."""
    if not items:
        return f"## {label}\n\n_(none extracted)_\n\n"
    out = [f"## {label}\n"]
    for it in items:
        if key_extractor:
            text = key_extractor(it)
        elif isinstance(it, dict):
            text = (it.get("quote") or it.get("description") or it.get("text") or
                    json.dumps(it, ensure_ascii=False))
        else:
            text = str(it)
        # Multi-line items get blockquoted; single-line as bullet
        if "\n" in text:
            for ln in text.strip().split("\n"):
                out.append(f"> {ln}")
            out.append("")
        else:
            out.append(f"- {text}")
    out.append("")
    return "\n".join(out)


def code_block(snippet) -> str:
    """Render a code snippet (dict OR str) as a fenced code block."""
    if isinstance(snippet, dict):
        lang = snippet.get("language") or ""
        body = (snippet.get("snippet_verbatim_or_close") or
                snippet.get("snippet") or
                snippet.get("code") or
                "")
        purpose = snippet.get("purpose") or ""
        out = [f"```{lang}", body.rstrip(), "```"]
        if purpose:
            out.append(f"_purpose:_ {purpose}")
        return "\n".join(out)
    return f"```\n{str(snippet).rstrip()}\n```"


# ─── manifest + extraction joining ──────────────────────────────────────────

def load_manifest(path: Path) -> dict:
    return json.loads(path.read_text())


def items_from_manifest(m: dict) -> list[dict]:
    items = m.get("chapters") or m.get("items") or []
    workshop_slug = m.get("workshop_slug")
    source_type = m.get("source_type") or ("workshop" if workshop_slug else "local-directory")
    out = []
    for entry in items:
        # Mirror the same full_label / short_id derivation batch_ingest does.
        if workshop_slug and "chapter_idx" in entry:
            slug_name = (entry.get("slug") or "").split("~")[0]
            full_label = f"{workshop_slug}-ch{int(entry['chapter_idx']):02d}-{slug_name}"
        else:
            full_label = entry.get("full_label") or Path(entry.get("mp4_path", "")).stem
        short_id = entry.get("short_id_override") or short_id_from_label(full_label)
        out.append({
            "short_id": short_id,
            "full_label": full_label,
            "source_type": source_type,
            "mp4_path": entry.get("mp4_path"),
            "output_json_path": str(UPLOAD_DIR / f"{short_id}-output.json"),
            "source_metadata": entry,
            "workshop_slug": workshop_slug,
            "root_label": m.get("root_label") or workshop_slug or "course",
        })
    return out


# ─── per-lesson markdown ────────────────────────────────────────────────────

def render_lesson_md(item: dict, extraction: dict | None) -> str:
    sm = item["source_metadata"]
    full_label = item["full_label"]
    short_id = item["short_id"]

    # Frontmatter — load-bearing for Obsidian search + downstream catalog
    # population.  full_label is the join key with the manifest; short_id
    # is the join key with extraction outputs.
    fm_lines = [
        "---",
        f"full_label: {yaml_quote(full_label)}",
        f"short_id: {yaml_quote(short_id)}",
        f"source_type: {yaml_quote(item['source_type'])}",
        f"mp4_path: {yaml_quote(item['mp4_path'])}",
        f"output_json_path: {yaml_quote(item['output_json_path'])}",
    ]
    if item.get("workshop_slug"):
        fm_lines.append(f"workshop_slug: {yaml_quote(item['workshop_slug'])}")
    if sm.get("module_idx") is not None:
        fm_lines.append(f"module_idx: {sm.get('module_idx')}")
        fm_lines.append(f"module_title: {yaml_quote(sm.get('module_title'))}")
    if sm.get("lesson_idx") is not None:
        fm_lines.append(f"lesson_idx: {sm.get('lesson_idx')}")
    if sm.get("chapter_idx") is not None:
        fm_lines.append(f"chapter_idx: {sm.get('chapter_idx')}")
    if sm.get("title"):
        fm_lines.append(f"title: {yaml_quote(sm.get('title'))}")
    if sm.get("muxPlaybackId"):
        fm_lines.append(f"mux_playback_id: {yaml_quote(sm.get('muxPlaybackId'))}")
    if extraction:
        fm_lines.append(f"prompt_profile: {yaml_quote(extraction.get('prompt_profile'))}")
        fm_lines.append(f"extracted_at: {yaml_quote(extraction.get('extracted_at'))}")
        fm_lines.append(f"model: {yaml_quote(extraction.get('model'))}")
        fm_lines.append(f"chunks_analyzed: {extraction.get('chunks_analyzed', 0)}")
        cs = extraction.get('cuda_stats') or {}
        if cs:
            fm_lines.append(f"cuda_free_post_cleanup_mb: {cs.get('free_mb_post_cleanup', 0)}")
            fm_lines.append(f"model_consumed_mb: {cs.get('model_consumed_mb', 0)}")
    fm_lines.append(f"curated: false")
    fm_lines.append(f"catalog_target: null  # set to app-maestro-catalog lesson_id once retrofitted")
    fm_lines.append(f"written_at: {yaml_quote(datetime.now(timezone.utc).isoformat())}")
    fm_lines.append("---")
    fm_str = "\n".join(fm_lines) + "\n\n"

    # Body
    body = ["# " + (sm.get("title") or full_label) + "\n"]
    body.append(f"`{short_id}` · _{item['source_type']}_ · " +
                (f"M{sm.get('module_idx'):02d}/L{sm.get('lesson_idx'):02d} · "
                 if sm.get("module_idx") and sm.get("lesson_idx") else "") +
                f"[mp4]({item['mp4_path']})")
    body.append("")

    if not extraction:
        body.append("_⚠ extraction output not yet present at "
                    f"`{item['output_json_path']}` — re-run this script after batch_ingest completes._\n")
        return fm_str + "\n".join(body)

    chunks = extraction.get("chunks") or []

    # The signal sections — laid out so the operator can read top-to-bottom
    # without jumping back and forth.  Each section is gated on having content.
    seg_summary = first_signal(chunks, "segment_summary")
    if isinstance(seg_summary, list) and seg_summary:
        seg_summary = (seg_summary[0].get("value") if isinstance(seg_summary[0], dict)
                       else seg_summary[0])
    if seg_summary:
        body.append("## Segment Summary\n")
        body.append(str(seg_summary).strip() + "\n")

    # Profile-agnostic field dump — any non-empty signal field becomes its
    # own section.  Skips the ones already rendered above.
    EXCLUDE = {"segment_summary"}
    field_titles = {
        "thesis_stated": "Thesis",
        "frameworks_taught": "Frameworks Taught",
        "frameworks_named": "Frameworks Named",
        "conceptual_steps": "Conceptual Steps",
        "design_choices_called_out": "Design Choices Called Out",
        "decisions_called_out": "Decisions Called Out",
        "decisions_a_founder_should_make": "Decisions a Founder Should Make",
        "alternatives_dismissed": "Alternatives Dismissed",
        "case_studies_referenced": "Case Studies Referenced",
        "exercises_or_worksheets_shown": "Exercises / Worksheets",
        "key_definitions": "Key Definitions",
        "common_mistakes_warned": "Common Mistakes Warned",
        "metrics_or_thresholds_stated": "Metrics / Thresholds",
        "pitfalls_warned": "Pitfalls Warned",
        "evidence_offered": "Evidence Offered",
        "contrarian_takes": "Contrarian Takes",
        "tools_or_resources_recommended": "Tools / Resources",
        "tools_mentioned": "Tools Mentioned",
        "dependencies_introduced": "Dependencies Introduced",
        "test_or_validation_shown": "Tests / Validation",
        "performance_callouts": "Performance Callouts",
        "code_snippets_if_shown": "Code Snippets",
        "code_or_pseudocode": "Code / Pseudocode",
        "visual_examples_described": "Visual Examples",
        "key_quotes": "Key Quotes",
        "actionable_for_learner": "Actionable Steps",
        "actionable_for_developer": "Actionable Steps",
        "actionable_for_founder": "Actionable Steps",
        "actionable_for_agent": "Actionable Steps",
        "open_questions_raised": "Open Questions",
        "final_artifact_described": "Final Artifact",
        "prerequisites_referenced": "Prerequisites Referenced",
        "risk_warnings": "Risk Warnings",
    }

    code_keys = {"code_snippets", "code_or_pseudocode", "code_snippets_if_shown"}

    for key, title in field_titles.items():
        if key in EXCLUDE:
            continue
        items = collect_signal(chunks, key)
        if not items:
            continue
        if key in code_keys:
            body.append(f"## {title}\n")
            for it in items[:5]:
                body.append(code_block(it))
                body.append("")
        else:
            body.append(md_quote_block(title, items[:10]))

    # Curation slots — these are the operator's editing surface.
    body.append("---\n")
    body.append("## Curation\n")
    body.append("_Edit below to capture the lesson as it will appear in the catalog._\n")
    body.append("### Key takeaway (operator)\n\n_TBD_\n")
    body.append("### How this maps to the catalog\n\n_TBD — name the lesson_id this will populate in `app-maestro-catalog/lessons/`._\n")
    body.append("### Vendor-strip notes (if applicable)\n\n_TBD_\n")
    body.append("### Cross-links\n\n_TBD_\n")

    # Raw extraction kept at the bottom for reference; strip after curation.
    body.append("---\n")
    body.append("## Raw extraction\n")
    body.append("<details><summary>full output.json (click to expand)</summary>\n")
    body.append("\n```json")
    body.append(json.dumps(extraction, indent=2, ensure_ascii=False)[:8000])
    if len(json.dumps(extraction)) > 8000:
        body.append("// (truncated — see full JSON at output_json_path)")
    body.append("```\n")
    body.append("</details>\n")

    return fm_str + "\n".join(body)


# ─── manifest index ────────────────────────────────────────────────────────

def render_index_md(items: list[dict], extractions: dict[str, dict], root_label: str) -> str:
    out = ["---"]
    out.append(f"manifest_root: {yaml_quote(root_label)}")
    out.append(f"item_count: {len(items)}")
    out.append(f"extracted_count: {sum(1 for it in items if it['short_id'] in extractions)}")
    out.append(f"written_at: {yaml_quote(datetime.now(timezone.utc).isoformat())}")
    out.append("---\n")
    out.append(f"# {root_label}\n")
    out.append("| # | M | L | title | extraction | full label |")
    out.append("|---|---|---|---|---|---|")
    for it in items:
        sm = it["source_metadata"]
        m = f"{sm.get('module_idx'):02d}" if sm.get("module_idx") is not None else "-"
        l_n = (f"{sm.get('lesson_idx'):02d}" if sm.get("lesson_idx") is not None
               else (f"{sm.get('chapter_idx'):02d}" if sm.get("chapter_idx") else "-"))
        ext = "✓" if it["short_id"] in extractions else "—"
        out.append(f"| {it['short_id']} | {m} | {l_n} | {sm.get('title','(no title)')} | {ext} | "
                   f"[[{it['full_label']}]] |")
    out.append("")
    return "\n".join(out)


# ─── main ──────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--manifest", required=True, type=Path)
    p.add_argument("--vault-root", type=Path, default=VAULT_ROOT_DEFAULT,
                   help=f"Obsidian vault root for course curation (default: {VAULT_ROOT_DEFAULT})")
    p.add_argument("--missing-ok", action="store_true",
                   help="emit notes even for items missing extraction output (default)")
    args = p.parse_args(argv)

    if not args.manifest.exists():
        sys.exit(f"FATAL: manifest not found: {args.manifest}")

    manifest = load_manifest(args.manifest)
    items = items_from_manifest(manifest)
    if not items:
        sys.exit(f"FATAL: no items in {args.manifest}")

    # Find which extractions have landed.
    extractions: dict[str, dict] = {}
    for it in items:
        out_json = Path(it["output_json_path"])
        if out_json.exists():
            try:
                extractions[it["short_id"]] = json.loads(out_json.read_text())
            except Exception as e:
                print(f"WARN: failed to parse {out_json}: {e}", file=sys.stderr)

    root_label = items[0]["root_label"]
    course_dir = args.vault_root / root_label
    course_dir.mkdir(parents=True, exist_ok=True)

    # Per-lesson .md
    written = 0
    for it in items:
        ext = extractions.get(it["short_id"])
        md = render_lesson_md(it, ext)
        target = course_dir / f"{it['full_label']}.md"
        target.write_text(md)
        marker = "✓" if ext else "○"
        print(f"  {marker} {target.relative_to(args.vault_root.parent)}")
        written += 1

    # Index
    idx = course_dir / "manifest.md"
    idx.write_text(render_index_md(items, extractions, root_label))
    print(f"  ✓ {idx.relative_to(args.vault_root.parent)} (index)")

    print()
    print(f"✓ {written} lesson notes + 1 index → {course_dir}")
    print(f"  extracted: {len(extractions)}/{written}")
    print(f"  pending  : {written - len(extractions)} (will be filled on next run when extraction lands)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
