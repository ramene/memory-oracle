#!/usr/bin/env python3
"""End-to-end driver for ONE cwa course → vault catalog.

Steps:
  1. Auto-derive chapter-dict.yaml from upstream cwa repo branches
  2. rsync SSD course mp4s → tunafish mirror
  3. Run cwa-transcribe.py on tunafish
  4. rsync transcripts back to local
  5. Run all 4 renderers (chapter assignment + lesson cards + scripts + marketing)
  6. Regenerate course _index.md

Per-course paths:
  SSD mp4s:        /Volumes/Extreme SSD/cwa/<ssd_dir>/
  tunafish mp4s:   ~/.local/share/<vault_slug>-mp4/
  transcripts:     ~/.local/share/<vault_slug>-transcripts/
  vault output:    ~/.remote/@vaults/.build/obsidian-vault/catalog/workshops/<vault_slug>/
  brand-spine:     ~/.remote/@vaults/.build/obsidian-vault/catalog/brand-spine/<vault_slug>-{scripts,marketing}/
  chapter dict:    ~/.remote/@vaults/.build/obsidian-vault/catalog/workshops/<vault_slug>/_meta/chapter-dict.yaml
"""
from __future__ import annotations
import argparse, subprocess, sys, time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SSD_BASE = Path("/Volumes/Extreme SSD/cwa")
CWA_BASE = Path.home() / ".remote/github.com/cwa"
VAULT_BASE = Path.home() / ".remote/@vaults/.build/obsidian-vault"

# Course map: (ssd_dir, vault_slug, upstream_repo)
COURSES = {
    "saas-ai-website-builder":   ("build-and-deploy-a-saas-ai-website-builder",  "nextjs-vibe"),
    "trello-clone":              ("trello-clone",                                "nextjs-trello-clone"),
    "duolingo-clone":            ("duolingo-clone",                              "nextjs-duolingo-clone"),
    "finance-platform":          ("build-a-finance-platform",                    "nextjs-finance-saas"),
    "ai-automation-saas":        ("build-and-deploy-an-ai-automation-saas",      "nodebase"),
    "twitch-clone":              ("twitch-clone",                                "nextjs-twitch-clone"),
    "miro-clone":                ("build-a-real-time-miro-clone",                "nextjs-miro-clone"),
    "canva-clone":               ("build-a-canva-clone",                         "nextjs-canva-clone"),
    "next-auth-v5":              ("next-auth-v5-advanced-guide",                 "nextjs-next-auth-v5-masterclass"),
    # 2026-06-25 — the 4 courses pulled to the SSD (see project_cwa_missing_videos_pulled_2026-06-25).
    # key = vault_slug (matches the prepped catalog/workshops/<key> placeholder dirs); ssd_dir = verbatim SSD folder.
    "youtube-clone":             ("youtube-clone",                                                       "next15-youtube-clone"),
    "polaris":                   ("build-and-deploy-a-cursor-clone",                                     "polaris"),
    "resonance":                 ("build-and-deploy-a-full-stack-elevenlabs-clone",                      "resonance"),
    "multitenant-ecommerce":     ("build-a-multi-tenant-e-commerce-with-nextjs-tailwind-v4-stripe-connect", "next15-multitenant-ecommerce"),
}


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd: list, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    log(f"  $ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, check=check, capture_output=capture, text=capture)


def process(slug: str, force: bool = False, skip_rsync: bool = False, skip_transcribe: bool = False) -> int:
    if slug not in COURSES:
        log(f"unknown course slug: {slug}")
        log(f"available: {', '.join(COURSES)}")
        return 1
    ssd_dir, upstream_repo = COURSES[slug]
    ssd_path = SSD_BASE / ssd_dir
    upstream_path = CWA_BASE / upstream_repo
    if not ssd_path.is_dir():
        log(f"✗ SSD dir not found: {ssd_path}")
        return 1
    tunafish_mp4_dir = f".local/share/{slug}-mp4"
    tunafish_xs_dir  = f".local/share/{slug}-transcripts"
    local_xs_dir     = Path.home() / f".local/share/{slug}-transcripts"
    vault_workshop   = VAULT_BASE / f"catalog/workshops/{slug}"
    vault_meta       = vault_workshop / "_meta"
    vault_lessons    = vault_workshop / "lessons"
    vault_scripts    = VAULT_BASE / f"catalog/brand-spine/{slug}-scripts"
    vault_marketing  = VAULT_BASE / f"catalog/brand-spine/{slug}-marketing"
    chapter_dict     = vault_meta / "chapter-dict.yaml"

    vault_meta.mkdir(parents=True, exist_ok=True)
    vault_lessons.mkdir(parents=True, exist_ok=True)
    vault_scripts.mkdir(parents=True, exist_ok=True)
    vault_marketing.mkdir(parents=True, exist_ok=True)

    log(f"═══ {slug} ═══")
    log(f"  SSD:        {ssd_path}")
    log(f"  upstream:   {upstream_path}")
    log(f"  tunafish:   ~/{tunafish_mp4_dir} → ~/{tunafish_xs_dir}")
    log(f"  vault:      {vault_workshop}")

    # 1. Chapter dict
    if not chapter_dict.exists() or force:
        log("[1/6] derive chapter dict from upstream branches")
        run([sys.executable, str(SCRIPT_DIR / "derive_chapter_dict.py"),
             slug, str(upstream_path), "-o", str(chapter_dict)])
    else:
        log(f"[1/6] chapter dict exists: {chapter_dict}")

    # 2. rsync SSD → tunafish
    if not skip_rsync:
        log("[2/6] rsync SSD mp4s → tunafish")
        run(["ssh", "tunafish", f"mkdir -p ~/{tunafish_mp4_dir}"])
        # rsync needs trailing slash on src for content-not-dir
        run(["rsync", "-a", "--progress",
             "--include=*.mp4", "--include=*/", "--exclude=*",
             f"{ssd_path}/", f"tunafish:~/{tunafish_mp4_dir}/"])
    else:
        log("[2/6] skip rsync (--skip-rsync)")

    # 3. Transcribe on tunafish (foreground; mlx-whisper saturates the GPU anyway)
    if not skip_transcribe:
        log("[3/6] run cwa-transcribe.py on tunafish")
        run(["ssh", "tunafish", f"python3 ~/.bin/cwa-transcribe.py {slug}"])
    else:
        log("[3/6] skip transcribe (--skip-transcribe)")

    # 4. Pull transcripts back
    log("[4/6] pull transcripts → local")
    local_xs_dir.mkdir(parents=True, exist_ok=True)
    run(["rsync", "-a", f"tunafish:~/{tunafish_xs_dir}/", f"{local_xs_dir}/"])

    # 5. Run all 4 renderers
    log("[5/6] infer chapter assignments")
    run([sys.executable, str(SCRIPT_DIR / "infer_chapter_assignment.py"),
         "--input-dir", str(local_xs_dir),
         "--output-dir", str(vault_meta),
         "--dict", str(chapter_dict)])

    log("[5/6] render per-lesson cards")
    cmd = [sys.executable, str(SCRIPT_DIR / "render_lesson_card.py"),
           "--input-dir", str(local_xs_dir),
           "--output-dir", str(vault_lessons)]
    if force: cmd.append("--force")
    run(cmd)

    log("[5/6] render script-generation prompts")
    cmd = [sys.executable, str(SCRIPT_DIR / "render_lesson_script.py"),
           "--input-dir", str(local_xs_dir),
           "--output-dir", str(vault_scripts)]
    if force: cmd.append("--force")
    run(cmd)

    log("[5/6] render marketing-copy prompts")
    cmd = [sys.executable, str(SCRIPT_DIR / "render_lesson_marketing.py"),
           "--input-dir", str(local_xs_dir),
           "--output-dir", str(vault_marketing)]
    if force: cmd.append("--force")
    run(cmd)

    # 6. _index.md (simple regen — point at the per-course chapter assignments)
    log("[6/6] write course _index.md")
    idx = vault_workshop / "_index.md"
    idx.write_text(_render_index(slug, vault_meta, vault_lessons))
    log(f"  ✓ {idx}")

    log(f"═══ {slug} done ═══")
    return 0


def _render_index(slug: str, vault_meta: Path, vault_lessons: Path) -> str:
    out = [f"# {slug} — re-implementation index", ""]
    out.append(f"> cwa course re-implemented in the operator's voice (Lachlan Dai).")
    out.append(f"> Source: `/Volumes/Extreme SSD/cwa/` · "
               f"Upstream: `~/.remote/github.com/cwa/`")
    out.append("")
    cards = sorted(vault_lessons.glob("l*.md"))
    out.append(f"**Status:** {len(cards)} lessons transcribed + cards rendered")
    out.append("")
    out.append("## Lessons")
    out.append("")
    for c in cards:
        out.append(f"- [[{c.relative_to(vault_meta.parent)}|{c.stem}]]")
    out.append("")
    out.append("## Per-chapter assignments")
    out.append("")
    assignments_md = vault_meta / "chapter-assignments.md"
    if assignments_md.exists():
        out.append(f"See [[_meta/chapter-assignments|chapter-assignments]] for the auto-inferred mapping.")
    return "\n".join(out) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("course", nargs="?", help="course slug (or 'all' to process every course in priority order)")
    p.add_argument("--force", action="store_true", help="overwrite existing outputs")
    p.add_argument("--skip-rsync", action="store_true", help="skip rsync SSD→tunafish")
    p.add_argument("--skip-transcribe", action="store_true", help="skip running cwa-transcribe.py on tunafish")
    p.add_argument("--list", action="store_true", help="list known courses")
    args = p.parse_args(argv)

    if args.list:
        for slug, (ssd, upstream) in COURSES.items():
            print(f"  {slug:24s}  ssd=/Volumes/Extreme SSD/cwa/{ssd}  upstream=~/.remote/github.com/cwa/{upstream}")
        return 0

    if not args.course:
        p.print_help()
        return 1

    if args.course == "all":
        # Priority order from operator (next-auth-v5 LAST per their directive)
        order = ["saas-ai-website-builder", "trello-clone", "duolingo-clone",
                 "finance-platform", "ai-automation-saas", "twitch-clone",
                 "miro-clone", "canva-clone", "next-auth-v5",
                 # 2026-06-25 additions (cwa SSD pull)
                 "youtube-clone", "polaris", "resonance", "multitenant-ecommerce"]
        for slug in order:
            rc = process(slug, force=args.force,
                         skip_rsync=args.skip_rsync, skip_transcribe=args.skip_transcribe)
            if rc != 0:
                log(f"✗ {slug} failed (rc={rc}); continuing to next")
        return 0
    return process(args.course, force=args.force,
                   skip_rsync=args.skip_rsync, skip_transcribe=args.skip_transcribe)


if __name__ == "__main__":
    sys.exit(main())
