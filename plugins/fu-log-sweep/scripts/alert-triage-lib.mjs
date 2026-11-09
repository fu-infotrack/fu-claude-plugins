// Pure helpers for /alert-triage: one Datadog monitor alert, synced from a
// Teams channel into a folder as a Microsoft Graph channel message, triaged
// against the log sweep's GitHub issues. No I/O, no clock — alert-triage.mjs
// does the reading, writing and calling. The error signature is
// log-sweep-lib's buildSignature, never a copy: an alert's error and a swept
// error must hash the same, or the alert files a duplicate.

import { buildSignature, buildLogQuery, issueMatchesBySig, classify, releaseCheck } from './log-sweep-lib.mjs';

const isStr = (v) => typeof v === 'string' && v.length > 0;
const getPath = (obj, dotted) => dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);

// The state Datadog puts in front of the monitor name: "[Triggered] Foo".
const STATE_RE = /^\s*\[(Triggered|Re-Triggered|Recovered|Warn|No Data)\]\s*(.*)$/i;
const CANON = { triggered: 'Triggered', 're-triggered': 'Re-Triggered', recovered: 'Recovered', warn: 'Warn', 'no data': 'No Data' };

// What a state asks for: triage it, close out an earlier triage, or just file it away.
export function actionFor(state) {
  if (state === 'Triggered' || state === 'Re-Triggered') return 'triage';
  if (state === 'Recovered') return 'recover';
  return 'archive';
}

// Parse one Graph channel message. Returns {ok:true, alert} or {ok:false, error}.
// alert: {id, state, title, monitorId, fromMs, toMs, eventId, site, monitorUrl,
// teamId, channelId, createdMs, webUrl}. monitorId/fromMs/toMs come from the
// card's "View in Datadog" URL; a message without one is not a monitor alert.
export function parseAlertMessage(msg) {
  if (!msg || typeof msg !== 'object') return { ok: false, error: 'not a JSON object' };
  if (!isStr(msg.id)) return { ok: false, error: 'no message id' };
  const m = (msg.summary || msg.subject || '').match(STATE_RE);
  if (!m) return { ok: false, error: `no [state] in summary ${JSON.stringify(msg.summary ?? null)}` };
  const state = CANON[m[1].toLowerCase()];
  let card = null;
  for (const a of msg.attachments || []) {
    try { card = typeof a.content === 'string' ? JSON.parse(a.content) : a.content; } catch { card = null; }
    if (card && card.type === 'AdaptiveCard') break;
    card = null;
  }
  const urls = [];
  const walk = (node) => {
    if (Array.isArray(node)) node.forEach(walk);
    else if (node && typeof node === 'object') {
      if (node.type === 'Action.OpenUrl' && isStr(node.url)) urls.push(node.url);
      Object.values(node).forEach(walk);
    }
  };
  walk(card);
  let link = null;
  for (const u of urls) {
    try {
      const url = new URL(u);
      if (/\/monitors\/\d+/.test(url.pathname)) { link = url; break; }
    } catch { /* not a URL */ }
  }
  if (!link) return { ok: false, error: 'no Datadog monitor link in the card' };
  const num = (k) => (link.searchParams.get(k) && Number.isFinite(Number(link.searchParams.get(k))) ? Number(link.searchParams.get(k)) : null);
  const created = Date.parse(msg.createdDateTime || '');
  return {
    ok: true,
    alert: {
      id: msg.id,
      state,
      title: m[2].trim(),
      monitorId: Number(link.pathname.match(/\/monitors\/(\d+)/)[1]),
      fromMs: num('from_ts'),
      toMs: num('to_ts'),
      eventId: link.searchParams.get('event_id'),
      site: link.origin,
      monitorUrl: `${link.origin}${link.pathname}`,
      teamId: msg.channelIdentity?.teamId || null,
      channelId: msg.channelIdentity?.channelId || null,
      createdMs: Number.isFinite(created) ? created : null,
      webUrl: msg.webUrl || null,
    },
  };
}

// The Logs query inside a log-alert monitor's query —
// logs("<q>").index("*").rollup("count").last("10m") > 0 — or null for any
// other monitor type.
export function logsQueryFromMonitor(monitorQuery) {
  const m = (monitorQuery || '').match(/^\s*logs\("((?:[^"\\]|\\.)*)"\)/);
  return m ? m[1].replace(/\\(["\\])/g, '$1') : null;
}

// Tag values for a key: tagValues(['repo:a','service:b'], 'repo') → ['a'].
export function tagValues(tags, key) {
  const p = `${key}:`;
  return (tags || []).filter((t) => isStr(t) && t.startsWith(p)).map((t) => t.slice(p.length)).filter(Boolean);
}

// The error-logs query for an alert: the monitor's own Logs query when it is a
// log alert, else status:error over the services it is tagged with. null when
// neither exists (nothing to read).
export function alertLogsQuery(monitor, env = 'prod') {
  const own = logsQueryFromMonitor(monitor?.query);
  if (own) return { query: own, source: 'monitor' };
  const services = tagValues(monitor?.tags, 'service');
  if (!services.length) return null;
  return { query: buildLogQuery(services, tagValues(monitor?.tags, 'env')[0] || env, 'status:error'), source: 'service-tags' };
}

// A Datadog facet (`@error.kind`) as a path on pup's raw log event.
export function facetPath(facet) {
  return `attributes.attributes.${String(facet || '').replace(/^@/, '')}`;
}

// Where a log with no exception type names its source, most specific first
// (Microsoft.Extensions.Logging EventId, then the Serilog/MEL logger name).
const KIND_FALLBACKS = ['properties.EventId.Name', 'Properties.EventId.Name', 'properties.SourceContext', 'Properties.SourceContext', 'SourceContext', 'logger.name'];

// Sign every event the way /log-sweep signs a bucket, and group by signature.
// shape: {errorFacet, stackPath, messagePath, appNamespace, versionTag}.
// The exception type is the facet's value, as in /log-sweep. An event without
// one (the sweep never buckets it) gets its logger's name instead, so a log
// line with no exception still lands under one stable signature.
// Returns [{sig, errorKind, service, frame, confidence, count, message,
// firstSeen, lastSeen, versions:[{version,count}], hasExceptionType}] by count desc.
export function signEvents(events, shape) {
  const groups = new Map();
  const ns = Array.isArray(shape.appNamespace) ? shape.appNamespace : [shape.appNamespace].filter(Boolean);
  const kindPath = facetPath(shape.errorFacet);
  const vtag = `${shape.versionTag || 'version'}:`;
  for (const ev of events || []) {
    const service = getPath(ev, 'attributes.service');
    if (!isStr(service)) continue;
    let errorKind = getPath(ev, kindPath);
    const hasExceptionType = isStr(errorKind);
    if (!hasExceptionType) {
      errorKind = KIND_FALLBACKS.map((p) => getPath(ev, `attributes.attributes.${p}`)).find(isStr) || 'log-error';
    }
    const stack = getPath(ev, shape.stackPath);
    const message = [getPath(ev, shape.messagePath), getPath(ev, 'attributes.attributes.MessageTemplate'), getPath(ev, 'attributes.message')].find(isStr) || '';
    const { sig, frame, confidence } = buildSignature(errorKind, service, isStr(stack) ? stack : '', message, ns);
    const ts = getPath(ev, 'attributes.timestamp');
    const version = (getPath(ev, 'attributes.tags') || []).find((t) => isStr(t) && t.startsWith(vtag));
    let g = groups.get(sig);
    if (!g) {
      g = { sig, errorKind, service, frame, confidence, count: 0, message: message.split('\n')[0].slice(0, 300), firstSeen: ts, lastSeen: ts, versions: {}, hasExceptionType };
      groups.set(sig, g);
    }
    g.count++;
    if (isStr(ts)) {
      if (!g.firstSeen || ts < g.firstSeen) g.firstSeen = ts;
      if (!g.lastSeen || ts > g.lastSeen) g.lastSeen = ts;
    }
    if (version) g.versions[version.slice(vtag.length)] = (g.versions[version.slice(vtag.length)] || 0) + 1;
  }
  return [...groups.values()]
    .map((g) => ({ ...g, versions: Object.entries(g.versions).map(([version, count]) => ({ version, count })) }))
    .sort((a, b) => b.count - a.count);
}

// Dedup each signed error against the repo's issues and apply /log-sweep's
// release gate to the closed ones. issues: REST issues (state=all); releases:
// [{tag, publishedAt}]. Adds {classification: NEW|ALREADY_OPEN|REGRESSION|HELD,
// issue?, gate?} to each error. A closed issue whose error recurs only on
// builds released before the close is HELD: the fix is not in prod yet.
export function classifyErrors(errors, issues, releases) {
  const bySig = issueMatchesBySig(issues);
  return errors.map((e) => {
    const matches = bySig[e.sig] || [];
    const c = classify(matches);
    if (c.kind === 'NEW') return { ...e, classification: 'NEW' };
    if (c.kind === 'ALREADY_OPEN') return { ...e, classification: 'ALREADY_OPEN', issue: c.number };
    const closed = matches.find((m) => m.number === c.number);
    const gate = releaseCheck(e.versions, releases, Date.parse(closed?.closedAt || ''));
    return { ...e, classification: gate.regressed ? 'REGRESSION' : 'HELD', issue: c.number, gate };
  });
}

// Other alerts that fired within `windowMs` of this one: the "several monitors
// at once" signal for an upstream outage. alerts: [{id, monitorId, title,
// state, atMs}]; returns the triggered ones, nearest first, excluding this
// alert and other alerts of the same monitor.
export function nearbyAlerts(self, alerts, windowMs) {
  const at = self.atMs;
  return (alerts || [])
    .filter((a) => a.id !== self.id && a.monitorId !== self.monitorId && actionFor(a.state) === 'triage')
    .filter((a) => Number.isFinite(a.atMs) && Math.abs(a.atMs - at) <= windowMs)
    .sort((a, b) => Math.abs(a.atMs - at) - Math.abs(b.atMs - at))
    .map((a) => ({ id: a.id, monitorId: a.monitorId, title: a.title, state: a.state, minutesFromThis: Math.round((a.atMs - at) / 60000) }));
}

// The model's verdict file. Returns {ok:true, value} or {ok:false, error}.
// {authorityDown, authority?, startIso?, ongoing?, summary, actions?: [string]}.
// An Authority-down verdict must name the Authority, a start and whether it
// is still failing — the brief's minimum for paging anyone.
export function validateVerdict(obj) {
  if (!obj || typeof obj.authorityDown !== 'boolean') return { ok: false, error: 'authorityDown must be true or false' };
  if (!isStr(obj.summary)) return { ok: false, error: 'summary is required' };
  const actions = obj.actions ?? [];
  if (!Array.isArray(actions) || actions.some((a) => !isStr(a))) return { ok: false, error: 'actions must be an array of strings' };
  if (!obj.authorityDown) return { ok: true, value: { authorityDown: false, summary: obj.summary, actions } };
  if (!isStr(obj.authority)) return { ok: false, error: 'an Authority-down verdict must name the authority' };
  if (!isStr(obj.startIso) || !Number.isFinite(Date.parse(obj.startIso))) return { ok: false, error: 'an Authority-down verdict needs an ISO startIso' };
  if (typeof obj.ongoing !== 'boolean') return { ok: false, error: 'an Authority-down verdict needs ongoing true or false' };
  return { ok: true, value: { authorityDown: true, authority: obj.authority, startIso: obj.startIso, ongoing: obj.ongoing, summary: obj.summary, actions } };
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// One line for a push notification (≤200 chars).
export function pushLine(alert, verdict) {
  return `${verdict.authority} down since ${verdict.startIso.slice(11, 16)}Z${verdict.ongoing ? ', ongoing' : ', recovered'} — ${alert.title}`.slice(0, 200);
}

// The webhook body for a reply on the alert's Teams message. The flow replies
// in the channel the alert came from, so the ids ride along; `text` is HTML,
// the format Teams' "Reply with a message in a channel" action renders.
export function teamsReplyPayload(alert, verdict) {
  const head = `<b>${esc(verdict.authority)} looks down</b> — since ${esc(verdict.startIso)}, ${verdict.ongoing ? '<b>still failing</b>' : 'recovered'}`;
  return {
    teamId: alert.teamId,
    channelId: alert.channelId,
    messageId: alert.id,
    text: `${head}<br>${esc(verdict.summary)}`,
  };
}

// The line a Recovered alert appends to the trigger's note.
export function recoveryLine(alert) {
  const at = alert.createdMs ? new Date(alert.createdMs).toISOString() : 'unknown time';
  return `\n**Recovered** at ${at} (message ${alert.id}).\n`;
}

// Of earlier triggers [{id, monitorId, atMs}], the latest for this monitor
// before the recovery — the note a recovery belongs to. null when none.
export function triggerFor(recovery, triggers) {
  return (triggers || [])
    .filter((t) => t.monitorId === recovery.monitorId && (!recovery.atMs || !t.atMs || t.atMs <= recovery.atMs))
    .sort((a, b) => (b.atMs || 0) - (a.atMs || 0))[0] || null;
}

// The text alert-watch sends a cloud routine's /fire endpoint for one
// triggered alert: everything the routine needs to start, so it never has to
// find the alert in OneDrive. `file` is where the alert JSON is archived.
export function fireText(alert, file) {
  const iso = (ms) => (ms ? new Date(ms).toISOString() : null);
  const facts = {
    id: alert.id, state: alert.state, title: alert.title,
    monitorId: alert.monitorId, monitorUrl: alert.monitorUrl, eventId: alert.eventId, site: alert.site,
    fromIso: iso(alert.fromMs), toIso: iso(alert.toMs), createdIso: iso(alert.createdMs),
    teamId: alert.teamId, channelId: alert.channelId, webUrl: alert.webUrl, file,
  };
  return `Datadog alert to triage (sent by alert-watch):\n\n\`\`\`json\n${JSON.stringify(facts, null, 2)}\n\`\`\`\n`;
}
