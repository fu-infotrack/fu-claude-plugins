// Pure, dependency-free helpers for the /log-sweep loop (except node:crypto,
// used by the fingerprint core in a later section — deterministic, no I/O).
// No network, no Date.now() — fully unit-testable.

import { createHash } from 'node:crypto';

const DAY_MS = 24 * 60 * 60 * 1000;

// Search window start (epoch ms). Always covers >= 24h, never reaches > 30d
// back, otherwise extends back to the last completed tick. First run => now-24h.
export function windowStartMs(lastTickMs, nowMs) {
  const floor = nowMs - DAY_MS;
  const cap = nowMs - 30 * DAY_MS;
  if (!lastTickMs) return floor;
  return Math.max(cap, Math.min(lastTickMs, floor));
}

// Classify a candidate from its GitHub marker-search matches.
// matches: [{number, state:'OPEN'|'CLOSED'}]. Open wins over closed (no churn).
export function classify(matches) {
  if (!matches || matches.length === 0) return { kind: 'NEW' };
  const open = matches.find((m) => m.state === 'OPEN');
  if (open) return { kind: 'ALREADY_OPEN', number: open.number };
  return { kind: 'REGRESSION', number: matches[0].number };
}

// GitHub issue title; truncates the message so the title stays around 80 chars.
export function buildTitle(errorType, message) {
  const shortType = errorType.includes('.') ? errorType.split('.').pop() : errorType;
  const prefix = `[Datadog] ${shortType}: `;
  const budget = Math.max(20, 80 - prefix.length);
  const oneLine = (message || '').replace(/\s+/g, ' ').trim();
  const msg = oneLine.length > budget ? `${oneLine.slice(0, budget - 1).trimEnd()}…` : oneLine;
  return prefix + msg;
}

// Parse a git remote URL to "owner/name" — github only, else null.
export function parseRepoFromRemote(url) {
  if (!url) return null;
  const m = url.match(/github\.com[/:]([^/]+)\/(.+?)(?:\.git)?\/?$/i);
  return m ? `${m[1]}/${m[2]}` : null;
}

// Distinct, order-preserving, empties removed.
export function collectServices(appNames) {
  const seen = new Set();
  const out = [];
  for (const n of appNames || []) {
    if (n && !seen.has(n)) { seen.add(n); out.push(n); }
  }
  return out;
}

// Datadog query across one or more services for an env.
export function buildServiceQuery(services, env) {
  const svc = services.length === 1 ? `service:${services[0]}` : `service:(${services.join(' OR ')})`;
  return `${svc} env:${env}`;
}

// Datadog Logs query: service+env scope plus the error status filter.
export function buildLogQuery(services, env, statusQuery) {
  return `${buildServiceQuery(services, env)} ${statusQuery || 'status:error'}`;
}

// Merge config layers for a tool: user < auto < project < cli (later wins).
export function mergeConfig(userObj, projectObj, autoObj, cliObj, tool) {
  const u = (userObj && userObj[tool]) || {};
  const p = (projectObj && projectObj[tool]) || {};
  const a = autoObj || {};
  const c = cliObj || {};
  return { ...u, ...a, ...p, ...c };
}

// ---- Fingerprint core (the dedup-signature computation) --------------------

const BCL_PREFIXES = ['System.', 'Microsoft.', 'Datadog.', 'Newtonsoft.', 'MediatR.', 'Polly.'];

// Parse .NET stack frames from an @error.stack string into an ordered array of
// qualified method names (no params/file/line), innermost first. Non-frame
// lines (the exception header, blank lines) are skipped.
export function parseFrames(stackText) {
  const out = [];
  for (const raw of (stackText || '').split('\n')) {
    const line = raw.trim();
    const m = line.match(/^at\s+(.+?)\s*(?:\(|$)/);
    if (m) out.push(m[1]);
  }
  return out;
}

// A framework/BCL frame (not the application's own code).
export function isBclFrame(qualifiedMethod) {
  return BCL_PREFIXES.some((p) => qualifiedMethod.startsWith(p));
}

// First frame whose qualified method starts with one of appNsPrefixes
// (e.g. ['Acme']). Returns the qualified method or null.
export function firstAppFrame(stackText, appNsPrefixes) {
  const prefixes = (appNsPrefixes || []).filter(Boolean);
  if (!prefixes.length) return null;
  for (const f of parseFrames(stackText)) {
    if (prefixes.some((p) => f.startsWith(p))) return f;
  }
  return null;
}

// First frame that is not a known BCL/framework frame — the fallback used when
// no app prefix is configured or none matched.
export function firstNonBclFrame(stackText) {
  for (const f of parseFrames(stackText)) {
    if (!isBclFrame(f)) return f;
  }
  return null;
}

// Normalize a qualified frame so it is stable across recompiles: unwrap async
// state machines and lambdas, drop generic arity backticks.
export function normalizeFrame(frame) {
  if (!frame) return '';
  let f = frame;
  f = f.replace(/\.<([^>]+)>d__\d+\.MoveNext$/, '.$1'); // async state machine
  f = f.replace(/\.<([^>]+)>b__[0-9_]+$/, '.$1');       // lambda / local function
  f = f.replace(/`\d+/g, '');                            // generic arity
  return f.trim();
}

// Normalize a message for the last-resort signature: mask guids and numbers so
// ids don't fragment it, collapse whitespace, cap at 80 chars.
export function normalizeMessage(message) {
  return (message || '')
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<guid>')
    .replace(/\d+/g, '<n>')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
}

// Stable 12-char signature from the grouping key parts.
export function computeSignature(errorKind, service, frameKey) {
  const key = `${errorKind || ''}|${service || ''}|${frameKey || ''}`;
  return createHash('sha1').update(key).digest('hex').slice(0, 12);
}

// Compute the dedup signature for one error bucket via the fallback ladder.
// Returns { sig, frame, confidence }.
export function buildSignature(errorKind, service, stackText, message, appNsPrefixes) {
  const app = firstAppFrame(stackText, appNsPrefixes);
  if (app) {
    const frame = normalizeFrame(app);
    return { sig: computeSignature(errorKind, service, frame), frame, confidence: 'app-frame' };
  }
  const nonBcl = firstNonBclFrame(stackText);
  if (nonBcl) {
    const frame = normalizeFrame(nonBcl);
    return { sig: computeSignature(errorKind, service, frame), frame, confidence: 'first-frame' };
  }
  const msg = normalizeMessage(message);
  return { sig: computeSignature(errorKind, service, msg), frame: null, confidence: 'message' };
}

const LOG_MARKER_RE = /<!--\s*dd-log-sig:\s*([0-9a-f]+)\s*-->/i;

export function buildMarker(sig) {
  return `<!-- dd-log-sig: ${sig} -->`;
}

export function extractSig(body) {
  const m = (body || '').match(LOG_MARKER_RE);
  return m ? m[1] : null;
}
