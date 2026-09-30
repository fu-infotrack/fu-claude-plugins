// Review-bot heartbeat Worker — the thin I/O shell around badge-lib.mjs.
//
//   POST /ping/<owner>/<repo>        Bearer PING_TOKEN; records the Worker's own time
//   GET  /badge/<owner>/<repo>.svg   that repo's bot: up/down + last ping, or "no bot"
//   GET  /badge.svg                  every live bot, one row each with its last ping, or "no bot active"
//
// Storage is the D1 binding DB. The table is created here on first use, so a
// deploy needs no migration step.
import { allBadge, renderSvg, repoBadge } from './badge-lib.mjs';

const SCHEMA = `CREATE TABLE IF NOT EXISTS pings (
  owner TEXT NOT NULL COLLATE NOCASE,
  repo TEXT NOT NULL COLLATE NOCASE,
  last_ping INTEGER NOT NULL,
  PRIMARY KEY (owner, repo))`;
const NAME = /^[A-Za-z0-9._-]{1,100}$/;

let schemaReady = false; // per isolate
async function ensureSchema(db) {
  if (schemaReady) return;
  await db.prepare(SCHEMA).run();
  schemaReady = true;
}

// Compare SHA-256 digests so timingSafeEqual always sees equal lengths.
async function tokenMatches(header, secret) {
  if (!secret || !header?.startsWith('Bearer ')) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(header.slice(7))),
    crypto.subtle.digest('SHA-256', enc.encode(secret)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

function svg(rows) {
  return new Response(renderSvg(rows), {
    headers: {
      'Content-Type': 'image/svg+xml; charset=utf-8',
      'Cache-Control': 'public, max-age=60',
    },
  });
}

export default {
  async fetch(request, env) {
    const parts = new URL(request.url).pathname.split('/').filter(Boolean);
    const now = Date.now();

    if (parts[0] === 'ping' && parts.length === 3) {
      if (request.method !== 'POST') return new Response(null, { status: 405 });
      if (!(await tokenMatches(request.headers.get('Authorization'), env.PING_TOKEN))) {
        return new Response(null, { status: 401 });
      }
      const [, owner, repo] = parts;
      if (!NAME.test(owner) || !NAME.test(repo)) return new Response(null, { status: 400 });
      await ensureSchema(env.DB);
      await env.DB.prepare(
        `INSERT INTO pings (owner, repo, last_ping) VALUES (?1, ?2, ?3)
         ON CONFLICT (owner, repo) DO UPDATE SET last_ping = excluded.last_ping`,
      ).bind(owner, repo, now).run();
      return new Response(null, { status: 204 });
    }

    if (request.method !== 'GET') return new Response(null, { status: 405 });

    if (parts.length === 1 && parts[0] === 'badge.svg') {
      await ensureSchema(env.DB);
      const { results } = await env.DB.prepare('SELECT repo, last_ping FROM pings').all();
      return svg(allBadge(results, now));
    }

    if (parts[0] === 'badge' && parts.length === 3 && parts[2].endsWith('.svg')) {
      const owner = parts[1];
      const repo = parts[2].slice(0, -'.svg'.length);
      if (!NAME.test(owner) || !NAME.test(repo)) return new Response(null, { status: 400 });
      await ensureSchema(env.DB);
      const row = await env.DB.prepare('SELECT last_ping FROM pings WHERE owner = ?1 AND repo = ?2')
        .bind(owner, repo).first();
      return svg([repoBadge(row?.last_ping, now)]);
    }

    return new Response(null, { status: 404 });
  },
};
