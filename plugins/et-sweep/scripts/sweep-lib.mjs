// Pure, dependency-free helpers for the /et-sweep loop.
// No I/O, no network, no Date.now() — fully unit-testable.

const DAY_MS = 24 * 60 * 60 * 1000;

// Search window start (epoch ms). Always covers >= 24h, never reaches > 30d
// back, otherwise extends back to the last completed tick. First run => now-24h.
export function windowStartMs(lastTickMs, nowMs) {
  const floor = nowMs - DAY_MS;       // newest allowed start (guarantees 24h)
  const cap = nowMs - 30 * DAY_MS;    // oldest allowed start (caps at 30d)
  if (!lastTickMs) return floor;
  return Math.max(cap, Math.min(lastTickMs, floor));
}

// Cheap candidate filter. issue: {firstSeenMs, isRegression, totalCount}.
export function passesFilter(issue, windowStart, countThreshold) {
  const recentOrRegressed = issue.firstSeenMs >= windowStart || issue.isRegression === true;
  return recentOrRegressed && issue.totalCount >= countThreshold;
}

// Classify a candidate from its GitHub marker-search matches.
// matches: [{number, state:'OPEN'|'CLOSED'}]. Open wins over closed (no churn).
export function classify(matches) {
  if (!matches || matches.length === 0) return { kind: 'NEW' };
  const open = matches.find((m) => m.state === 'OPEN');
  if (open) return { kind: 'ALREADY_OPEN', number: open.number };
  return { kind: 'REGRESSION', number: matches[0].number };
}

const MARKER_RE = /<!--\s*dd-et-issue:\s*([0-9a-f-]+)\s*-->/i;

export function buildMarker(issueId) {
  return `<!-- dd-et-issue: ${issueId} -->`;
}

export function extractIssueId(body) {
  const m = (body || '').match(MARKER_RE);
  return m ? m[1] : null;
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

// Merge config layers for a tool: user < auto < project < cli (later wins).
export function mergeConfig(userObj, projectObj, autoObj, cliObj, tool) {
  const u = (userObj && userObj[tool]) || {};
  const p = (projectObj && projectObj[tool]) || {};
  const a = autoObj || {};
  const c = cliObj || {};
  return { ...u, ...a, ...p, ...c };
}
