---
name: FUNCTION-loadSupersessions
description: Sidecar loader function in memory-merge.mjs that reads .supersessions.jsonl.
metadata:
  type: function
  authored_at: 2026-04-22T10:00:00Z
  file: bin/memory-merge.mjs
  function: loadSupersessions
---

# function loadSupersessions(memoryFilePath) in bin/memory-merge.mjs

The merge primitive's sidecar loader. Given a canonical memory file
path, it reads the companion `.supersessions.jsonl` sidecar and
returns an array of supersession records (one per JSONL line).

Current implementation:

```javascript
function loadSupersessions(memoryFilePath) {
  const sidecar = memoryFilePath + '.supersessions.jsonl';
  if (!existsSync(sidecar)) return [];
  const raw = readFileSync(sidecar, 'utf8');
  // ...parse JSONL, return records...
}
```

Single sidecar extension recognized: `.supersessions.jsonl`. No
fallback path; if the file is missing, empty array is returned.

Used by `bin/memory-merge.mjs` main loop and by `bin/memory-index-build.mjs`.
