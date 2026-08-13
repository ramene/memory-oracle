#!/usr/bin/env node
// watch-video-teardown.mjs — PROMPT #1 of master-video-teardown, run as a single Gemini WATCH pass.
// Clone of watch-video-scope.mjs with the forensic-teardown prompt (ROLE + HARD RULES + the 13-section
// Phase-6 structure) so Gemini emits the teardown directly. For short videos (single pass). Writes .teardown.md
//   MODEL=gemini-2.5-pro node watch-video-teardown.mjs <video.mp4>
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import { homedir } from 'node:os';
const API = 'https://generativelanguage.googleapis.com';
const MODEL = process.env.MODEL || 'gemini-2.5-pro';
const EXT = { '.mov':'video/quicktime','.mp4':'video/mp4','.m4v':'video/x-m4v','.webm':'video/webm','.mkv':'video/x-matroska' };
function key() {
  for (const p of [join(homedir(),'.claude/.credentials/gemini-api-key.txt'), join(homedir(),'.local/share/journal/.claude/.credentials/gemini-api-key.txt')]) { try { return readFileSync(p,'utf8').trim(); } catch {} }
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY.trim();
  throw new Error('No Gemini key');
}
function pick(args){ const v=args.find(a=>!a.startsWith('-')); if(!v) throw new Error('give a video path'); return v; }

const PROMPT = `ROLE
You are a forensic short-form video analyst. You are WATCHING and LISTENING to this video natively. Tear it down completely — every cut, every spoken word, every on-screen element, every audio choice — so a competent editor could rebuild it from your notes alone, without ever seeing the original. Do not summarize. Do not skim. Do not guess. Measure everything you claim from what you actually see and hear.

HARD RULES (violating any invalidates the teardown)
- Captions are NOT the script. Transcribe the SPOKEN AUDIO separately and treat that as the source of truth. If burned-in captions are present, diff them against the audio and report every disagreement. Never present on-screen text as dialogue.
- Distinguish three kinds of on-screen text and report them in SEPARATE lists: (a) burned-in captions/subtitles; (b) designed graphics (title cards, animated charts, lower-thirds, end cards — text that is part of the design); (c) platform chrome (TikTok/IG logos, @handles, watermarks, UI buttons, "scan me"/QR). A designed animated card is NOT a caption.
- Report the ACTUAL cuts and their timestamps as you observe them — do not assume the cut rhythm. Note match-cuts, punch-ins, dissolves, freeze-frames.
- Read every legible on-screen text/UI verbatim (prompts, labels, app screens, documents, packaging) — that content is often the most valuable part.
- State uncertainty: if a word is garbled or a detail is unreadable, mark it ⚠️ and say what you think it is WITHOUT asserting it as fact. Never invent a plausible word to fill a gap.
- Timestamps come from what you actually observe, in m:ss.

OUTPUT — GFM Markdown with EXACTLY these 13 sections, in order:
1. Snapshot — one paragraph: what this video is, who made it, what it's selling/teaching, and the single reason it works.
2. Technical spec — duration, aspect ratio, apparent fps, audio presence, total cuts, average shot length, cuts/min (from your observation).
3. Format DNA — the reusable structural pattern; NAME the format so it can be reused.
4. Cast, wardrobe, set, props — everyone on screen described precisely enough to recast (age range, hair, wardrobe, accessories, demeanour); set/background; full props inventory.
5. Camera, lighting, grade — lens feel, framing sizes, movement (locked/handheld/gimbal), angles, depth of field; lighting direction/quality/temperature/practicals; colour-grade character and any deliberate grade shifts.
6. Verbatim transcript (from audio) — timestamped, ⚠️ on anything uncertain.
7. Shot-by-shot timeline — for every shot between cuts: timestamp range, shot size & angle, camera movement, what's in frame, what's spoken over it, on-screen text (typed by category a/b/c), VFX, SFX.
8. On-screen text inventory — three separate lists: (a) burned-in captions incl. font weight/colour/position/emphasis; (b) designed graphics described as designs with their text transcribed; (c) platform chrome to EXCLUDE on any recreation.
9. Audio design — voice (mic/quality/delivery), music (genre, energy, where it enters/ducks/lifts/resolves), SFX inventory with timestamps, use of silence.
10. Pacing analysis — a beat table (Beat | Start–End | Length | Shot type | Words | Speech time | Air) plus word count and words-per-minute.
11. Persuasion / retention structure — hook type, what earns attention in the first 3 seconds, how curiosity is sustained, proof devices, objection handling, CTA mechanics, the final button.
12. Recreation blueprint — a shot list, prop/casting checklist, what must be captured as real footage vs. what can be AI-generated, and (since this feeds Seedance) a copy-paste generation direction per shot.
13. What I could not determine — unreadable text, ambiguous audio, anything you could not verify. Be specific.

Return ONLY the markdown, starting at "# Teardown: <short title>".`;

async function main(){
  const k=key(); const video=pick(process.argv.slice(2));
  const bytes=readFileSync(video); const mime=EXT[extname(video).toLowerCase()]||'video/mp4';
  console.error(`[teardown] ${basename(video)} (${(bytes.length/1e6).toFixed(1)} MB) -> Gemini ${MODEL}`);
  const s=await fetch(`${API}/upload/v1beta/files?key=${k}`,{method:'POST',headers:{'X-Goog-Upload-Protocol':'resumable','X-Goog-Upload-Command':'start','X-Goog-Upload-Header-Content-Length':String(bytes.length),'X-Goog-Upload-Header-Content-Type':mime,'Content-Type':'application/json'},body:JSON.stringify({file:{display_name:basename(video)}})});
  if(!s.ok) throw new Error(`start ${s.status}: ${await s.text()}`);
  const up=s.headers.get('x-goog-upload-url'); if(!up) throw new Error('no upload url');
  const u=await fetch(up,{method:'POST',headers:{'X-Goog-Upload-Command':'upload, finalize','X-Goog-Upload-Offset':'0'},body:bytes});
  if(!u.ok) throw new Error(`upload ${u.status}: ${await u.text()}`);
  let f=(await u.json()).file; console.error(`[teardown] uploaded ${f.name} state=${f.state}`);
  while(f.state==='PROCESSING'){ await new Promise(r=>setTimeout(r,4000)); f=await(await fetch(`${API}/v1beta/${f.name}?key=${k}`)).json(); console.error(`[teardown] ${f.state}...`); }
  if(f.state!=='ACTIVE') throw new Error(`not ACTIVE: ${JSON.stringify(f).slice(0,300)}`);
  const g=await fetch(`${API}/v1beta/models/${MODEL}:generateContent?key=${k}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({contents:[{parts:[{file_data:{mime_type:mime,file_uri:f.uri}},{text:PROMPT}]}],generationConfig:{temperature:0.2,maxOutputTokens:32768}})});
  if(!g.ok) throw new Error(`generate ${g.status}: ${await g.text()}`);
  const md=(await g.json()).candidates?.[0]?.content?.parts?.map(p=>p.text).join('')||'(no output)';
  const out=video.replace(extname(video),'.teardown.md'); writeFileSync(out,md);
  console.error(`[teardown] -> ${out}`); process.stdout.write(md+'\n');
}
main().catch(e=>{console.error('[teardown] ERROR:',e.message);process.exit(1);});
