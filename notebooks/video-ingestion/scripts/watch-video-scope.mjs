#!/usr/bin/env node
// watch-video-scope.mjs — Watch a screen recording (screen + operator narration) via
// Gemini NATIVE video understanding and emit a CONSOLIDATED scope-of-work + design
// spec (markdown). Replaces the Deepnote/Qwen-VL path (warm-kernel 19GB OOM →
// silent _inference_error + crashes; see card deepnote-oom-patch-ineffective).
// Gemini watches video+audio natively: no GPU, no OOM, no L4 cost.
//
// Usage:
//   node watch-video-scope.mjs <video.mov>
//   node watch-video-scope.mjs --latest [dir]     # newest video (default ~/Desktop/latest-test)
//   MODEL=gemini-2.5-pro node watch-video-scope.mjs --latest
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import { homedir } from 'node:os';
const API = 'https://generativelanguage.googleapis.com';
const MODEL = process.env.MODEL || 'gemini-2.5-flash';
const EXT = { '.mov':'video/quicktime','.mp4':'video/mp4','.m4v':'video/x-m4v','.webm':'video/webm','.mkv':'video/x-matroska' };
function key() {
  for (const p of [join(homedir(),'.claude/.credentials/gemini-api-key.txt'), join(homedir(),'.local/share/journal/.claude/.credentials/gemini-api-key.txt')]) { try { return readFileSync(p,'utf8').trim(); } catch {} }
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY.trim();
  throw new Error('No Gemini key (~/.claude/.credentials/gemini-api-key.txt or GEMINI_API_KEY)');
}
function pick(args) {
  const li = args.indexOf('--latest');
  if (li !== -1) {
    const dir = args[li+1] && !args[li+1].startsWith('-') ? args[li+1] : join(homedir(),'Desktop/latest-test');
    const v = readdirSync(dir).filter(f => EXT[extname(f).toLowerCase()]).map(f => ({f:join(dir,f),t:statSync(join(dir,f)).mtimeMs})).sort((a,b)=>b.t-a.t);
    if (!v.length) throw new Error(`No video in ${dir}`); return v[0].f;
  }
  const v = args.find(a => !a.startsWith('-')); if (!v) throw new Error('give a video path or --latest'); return v;
}
const PROMPT = `You are watching a screen recording by the operator (Ramene), who tests software (usually the "mae" Obsidian plugin / lmcanvas) and NARRATES out loud every change, tweak, fix, and design decision they want. WATCH the screen AND LISTEN to the narration, then produce ONE consolidated scope-of-work + design spec a senior engineer can implement in one sweep WITHOUT the video. Be exhaustive; capture EVERYTHING; when they point at something, name the on-screen target (component/button/panel/label); infer file/component names when visible or implied.
Output GFM Markdown with EXACTLY:
# Scope: <short title>
## Context
## Requested changes (the work)
(numbered; each: imperative task, on-screen target, stated reasoning, file/component hint; group related; miss nothing)
## Design decisions & constraints
## Open questions / ambiguities
## Acceptance criteria
## Timestamps
(mm:ss -> what said/shown)
Return ONLY the markdown.`;
async function main() {
  const k = key(); const video = pick(process.argv.slice(2));
  const bytes = readFileSync(video); const mime = EXT[extname(video).toLowerCase()] || 'video/mp4';
  console.error(`[watch] ${basename(video)} (${(bytes.length/1e6).toFixed(1)} MB) -> Gemini ${MODEL}`);
  const s = await fetch(`${API}/upload/v1beta/files?key=${k}`, { method:'POST', headers:{'X-Goog-Upload-Protocol':'resumable','X-Goog-Upload-Command':'start','X-Goog-Upload-Header-Content-Length':String(bytes.length),'X-Goog-Upload-Header-Content-Type':mime,'Content-Type':'application/json'}, body:JSON.stringify({file:{display_name:basename(video)}}) });
  if (!s.ok) throw new Error(`start ${s.status}: ${await s.text()}`);
  const up = s.headers.get('x-goog-upload-url'); if (!up) throw new Error('no upload url');
  const u = await fetch(up, { method:'POST', headers:{'X-Goog-Upload-Command':'upload, finalize','X-Goog-Upload-Offset':'0'}, body:bytes });
  if (!u.ok) throw new Error(`upload ${u.status}: ${await u.text()}`);
  let f = (await u.json()).file; console.error(`[watch] uploaded ${f.name} state=${f.state}`);
  while (f.state === 'PROCESSING') { await new Promise(r=>setTimeout(r,4000)); f = await (await fetch(`${API}/v1beta/${f.name}?key=${k}`)).json(); console.error(`[watch] ${f.state}...`); }
  if (f.state !== 'ACTIVE') throw new Error(`not ACTIVE: ${JSON.stringify(f).slice(0,300)}`);
  const g = await fetch(`${API}/v1beta/models/${MODEL}:generateContent?key=${k}`, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ contents:[{parts:[{file_data:{mime_type:mime,file_uri:f.uri}},{text:PROMPT}]}], generationConfig:{temperature:0.2,maxOutputTokens:16384} }) });
  if (!g.ok) throw new Error(`generate ${g.status}: ${await g.text()}`);
  const md = (await g.json()).candidates?.[0]?.content?.parts?.map(p=>p.text).join('') || '(no output)';
  const out = video.replace(extname(video), '.scope.md'); writeFileSync(out, md);
  console.error(`[watch] scope -> ${out}`); process.stdout.write(md + '\n');
}
main().catch(e => { console.error('[watch] ERROR:', e.message); process.exit(1); });
