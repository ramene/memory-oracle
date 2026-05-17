#!/usr/bin/env node
// memory-oracle REST API — Express + bearer-token auth.
// Same handlers as the MCP server; different transport for cross-machine consumers.
//
// Env vars:
//   MEMORY_ORACLE_TOKEN  — required. Bearer token clients must present in Authorization header.
//   PORT                 — default 3737
//
// Run: MEMORY_ORACLE_TOKEN=$(openssl rand -hex 32) node packages/api/server.mjs

import http from 'node:http';
import { URL } from 'node:url';
import { HANDLERS } from '../core/handlers.mjs';

const PORT = parseInt(process.env.PORT || '3737', 10);
const TOKEN = process.env.MEMORY_ORACLE_TOKEN;

if (!TOKEN) {
  console.error('MEMORY_ORACLE_TOKEN env var is required. Generate with: openssl rand -hex 32');
  process.exit(2);
}

function send(res, code, payload) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload));
}

async function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', c => data += c.toString());
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('invalid JSON body')); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  // Auth: bearer token required for all routes except /healthz
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname === '/healthz') return send(res, 200, { ok: true, version: '0.1.0' });

  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ') || auth.slice(7) !== TOKEN) {
    return send(res, 401, { error: 'unauthorized' });
  }

  try {
    const path = url.pathname;
    let result;

    if (req.method === 'GET' && path === '/search') {
      const q = Object.fromEntries(url.searchParams);
      result = await HANDLERS.memory_search({
        query: q.q || q.query,
        project: q.project,
        k: parseInt(q.k || '10', 10),
        budget: parseInt(q.budget || '30000', 10),
      });
    }
    else if (req.method === 'POST' && path === '/search') {
      const body = await readBody(req);
      result = await HANDLERS.memory_search(body);
    }
    else if (req.method === 'POST' && path === '/cite') {
      const body = await readBody(req);
      result = await HANDLERS.memory_cite(body);
    }
    else if (req.method === 'POST' && path === '/supersede') {
      const body = await readBody(req);
      result = await HANDLERS.memory_supersede(body);
    }
    else if (req.method === 'GET' && path === '/stats') {
      result = await HANDLERS.memory_stats();
    }
    else if (req.method === 'GET' && path === '/info') {
      result = await HANDLERS.memory_info();
    }
    else {
      return send(res, 404, { error: 'not found', available: ['GET /search', 'POST /search', 'POST /cite', 'POST /supersede', 'GET /stats', 'GET /info', 'GET /healthz'] });
    }
    send(res, 200, result);
  } catch (e) {
    send(res, 500, { error: e.message });
  }
});

server.listen(PORT, () => {
  console.error(`[memory-oracle API] listening on :${PORT} (token auth required)`);
});
