#!/usr/bin/env node
// The deterministic half of /alert-triage: everything but the judgement.
// alert-watch calls it once per alert file in the inbox:
//
//   node alert-triage.mjs handle <file>   route one alert; prints ONE status line:
//     ARCHIVED <id> <reason>        Warn / No Data / out of scope / stale / unparseable
//     RECOVERED <id> <trigger-id|-> a Recovered alert, noted on its trigger's note
//     TRIAGE<TAB><id><TAB><facts><TAB><cwd>  facts written (tab-separated: the
//                                   paths hold spaces); run /alert-triage on
//                                   <facts> from <cwd>, then `finish`
//     RETRY <id> <reason>           leave it in the inbox for the next poll
//   node alert-triage.mjs finish <file>   after the command: check its verdict,
//     notify on an Authority-down verdict, archive. Prints DONE / RETRY / FAILED.
//   node alert-triage.mjs fire <file>     what alert-watch runs: a message whose
//     summary starts with "[Triggered]" is sent, verbatim, as the cloud
//     routine's fire text (`fire_url`, bearer token from $ALERT_TRIAGE_FIRE_TOKEN).
//     No card parsing here. Prints ONE line:
//     ARCHIVED <id> <reason>        anything else, or older than max_age_hours
//     FIRED <id> <session url|->    the routine accepted it; alert archived
//     RETRY <id> <reason>           left in the inbox for the next poll
//     FAILED <id> <reason>          refused 3 times; archived with a note
//   node alert-triage.mjs config          the resolved config (JSON)
//
// Archiving moves the alert JSON to processed/ next to the inbox; that move is
// what makes a second poll skip it. Its note (<id>.md), facts and verdict sit
// beside it. ALERT_TRIAGE_DRY_RUN=1: observe mode, nothing moved, nothing sent.
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mergeConfig } from './log-sweep-lib.mjs';
import { pupRunner } from './collect.mjs';
import {
  parseAlertMessage, actionFor, alertLogsQuery, tagValues, signEvents, classifyErrors,
  nearbyAlerts, validateVerdict, pushLine, teamsReplyPayload, recoveryLine, triggerFor,
} from './alert-triage-lib.mjs';

const SCRIPTS = path.dirname(fileURLToPath(import.meta.url));
const DRY = process.env.ALERT_TRIAGE_DRY_RUN === '1';
const MAX_ATTEMPTS = 3;
const NEARBY_MS = 15 * 60 * 1000;
const LOG_LIMIT = 500;
const MAX_ERRORS = 20;

const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const out = (line) => process.stdout.write(`${line}\n`);
const expand = (p) => (p || '').replace(/^~(?=\/|$)/, os.homedir());

function loadConfig() {
  const user = readJson(path.join(os.homedir(), '.claude', 'fu-tools', 'config.json'));
  let proj = null;
  for (let dir = process.cwd(); ; dir = path.dirname(dir)) {
    const cand = path.join(dir, '.claude', '.fu-tools.json');
    if (fs.existsSync(cand)) { proj = readJson(cand); break; }
    if (dir === path.dirname(dir)) break;
  }
  const c = mergeConfig(user, proj, null, null, 'alert-triage');
  return {
    inbox: expand(process.env.ALERT_TRIAGE_INBOX || c.inbox || ''),
    monitors: (c.monitors || []).map(Number),
    repoRoot: expand(c.repo_root || '~/repo'),
    env: c.env || 'prod',
    mode: DRY ? 'observe' : (c.mode === 'observe' ? 'observe' : 'live'),
    maxAgeHours: Number(c.max_age_hours) || 24,
    teamsWebhook: c.teams_webhook || null,
    authorityPrompt: c.authority_prompt || null,
    toast: c.toast !== false,
    model: c.model || null,
    fireUrl: c.fire_url || null,
    fireToken: process.env.ALERT_TRIAGE_FIRE_TOKEN || null,
  };
}

const processedDir = (file) => path.join(path.dirname(path.dirname(path.resolve(file))), 'processed');
const paths = (file, id) => {
  const d = processedDir(file);
  return { dir: d, json: path.join(d, `${id}.json`), note: path.join(d, `${id}.md`), facts: path.join(d, `${id}.facts.json`), verdict: path.join(d, `${id}.verdict.json`), attempts: path.join(d, `${id}.attempts`) };
};

function archive(file, dest) {
  if (DRY) return;
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.renameSync(file, dest);
}

function writeNote(p, text) {
  if (DRY) return;
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text);
}

// Every alert message in the inbox and processed/ (last 3 days by mtime), parsed.
function knownAlerts(file) {
  const dirs = [path.dirname(path.resolve(file)), processedDir(file)];
  const since = Date.now() - 3 * 24 * 3600 * 1000;
  const list = [];
  for (const d of dirs) {
    let names = [];
    try { names = fs.readdirSync(d); } catch { continue; }
    for (const n of names) {
      if (!/^[^.]+\.json$/.test(n)) continue;
      const p = path.join(d, n);
      try { if (fs.statSync(p).mtimeMs < since) continue; } catch { continue; }
      const r = parseAlertMessage(readJson(p));
      if (r.ok) list.push({ ...r.alert, atMs: r.alert.createdMs, dir: d });
    }
  }
  return list;
}

// The local clone a `repo:` tag names: a directory under repoRoot whose name
// matches case-insensitively (`repo:foo.bar` → ~/repo/Foo.Bar). null if none.
function findClone(root, tag) {
  if (!tag) return null;
  let names = [];
  try { names = fs.readdirSync(root); } catch { return null; }
  const hit = names.find((n) => n.toLowerCase() === tag.toLowerCase() && fs.existsSync(path.join(root, n, '.git')));
  return hit ? path.join(root, hit) : null;
}

// The repo's log shape and GitHub repo, resolved exactly as /log-sweep does:
// `sweep.mjs resolve` with the clone as cwd, so its .fu-tools.json applies.
function resolveShape(cwd) {
  return JSON.parse(execFileSync(process.execPath, [path.join(SCRIPTS, 'sweep.mjs'), 'resolve', '{}'], { cwd, encoding: 'utf8' }));
}

function ghJson(args) {
  return JSON.parse(execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }));
}

// Every issue with the sweep's label, REST pages (the routine's listing).
function listIssues(repo) {
  const all = [];
  for (let page = 1; page <= 20; page++) {
    const batch = ghJson(['api', `repos/${repo}/issues?state=all&labels=datadog-logs&per_page=100&page=${page}`]);
    all.push(...batch);
    if (batch.length < 100) break;
  }
  return all;
}

async function prepare(file, alert, cfg, p) {
  const pup = pupRunner({ site: alert.site });
  let monitor = await pup(['monitors', 'get', String(alert.monitorId)]);
  if (monitor && monitor.data && !monitor.id) monitor = monitor.data;
  const repoTag = tagValues(monitor.tags, 'repo')[0] || null;
  const clone = findClone(cfg.repoRoot, repoTag);
  const shape = resolveShape(clone || os.homedir());
  const github = clone ? shape.repo : null;

  const toMs = alert.toMs || alert.createdMs || Date.now();
  const fromMs = alert.fromMs || toMs - 20 * 60 * 1000;
  const window = { fromIso: new Date(fromMs).toISOString(), toIso: new Date(toMs).toISOString() };
  const q = alertLogsQuery(monitor, cfg.env);
  let events = [];
  if (q) {
    const res = await pup(['logs', 'search', '--storage', 'indexes', '--query', q.query, '--from', window.fromIso, '--to', window.toIso, '--limit', String(LOG_LIMIT)]);
    events = Array.isArray(res.data) ? res.data : [];
  }
  let errors = signEvents(events, shape);
  let githubError = null;
  if (github && errors.length) {
    try {
      const releases = ghJson(['api', `repos/${github}/releases?per_page=30`]).map((r) => ({ tag: r.tag_name, publishedAt: r.published_at }));
      errors = classifyErrors(errors, listIssues(github), releases);
    } catch (e) {
      githubError = String(e.stderr || e.message).trim().split('\n')[0];
    }
  }
  const self = { ...alert, atMs: alert.createdMs };
  const facts = {
    mode: cfg.mode,
    alert: { id: alert.id, state: alert.state, title: alert.title, createdIso: alert.createdMs ? new Date(alert.createdMs).toISOString() : null, monitorUrl: alert.monitorUrl, eventId: alert.eventId, webUrl: alert.webUrl },
    monitor: { id: monitor.id, name: monitor.name, type: monitor.type, query: monitor.query, tags: monitor.tags || [] },
    window,
    logsQuery: q ? q.query : null,
    logsQuerySource: q ? q.source : 'none',
    sampledEvents: events.length,
    sampleCapped: events.length >= LOG_LIMIT,
    repo: { tag: repoTag, clone, github },
    shape: { errorFacet: shape.errorFacet, stackPath: shape.stackPath, messagePath: shape.messagePath, appNamespace: shape.appNamespace, versionTag: shape.versionTag, logsUrlBase: shape.logsUrlBase, env: shape.env },
    githubError,
    errors: errors.slice(0, MAX_ERRORS),
    errorsDropped: Math.max(0, errors.length - MAX_ERRORS),
    nearbyAlerts: nearbyAlerts(self, knownAlerts(file), NEARBY_MS),
    authorityPrompt: cfg.authorityPrompt,
    notePath: p.note,
    verdictPath: p.verdict,
  };
  fs.mkdirSync(p.dir, { recursive: true });
  fs.writeFileSync(p.facts, `${JSON.stringify(facts, null, 2)}\n`);
  return clone || os.homedir();
}

async function handle(file, cfg) {
  const msg = readJson(file);
  const r = parseAlertMessage(msg);
  const id = (msg && msg.id) || path.basename(file, '.json');
  const p = paths(file, id);
  if (!r.ok) {
    writeNote(p.note, `**Not triaged** — ${r.error}.\n`);
    archive(file, p.json);
    return out(`ARCHIVED ${id} unparseable: ${r.error}`);
  }
  const a = r.alert;
  if (cfg.monitors.length && !cfg.monitors.includes(a.monitorId)) {
    archive(file, p.json);
    return out(`ARCHIVED ${id} monitor ${a.monitorId} not in scope`);
  }
  const action = actionFor(a.state);
  if (action === 'archive') {
    archive(file, p.json);
    return out(`ARCHIVED ${id} ${a.state}`);
  }
  if (action === 'recover') {
    const triggers = knownAlerts(file).filter((k) => k.dir === p.dir && actionFor(k.state) === 'triage');
    const t = triggerFor({ ...a, atMs: a.createdMs }, triggers);
    if (t && !DRY) fs.appendFileSync(path.join(p.dir, `${t.id}.md`), recoveryLine(a));
    archive(file, p.json);
    return out(`RECOVERED ${id} ${t ? t.id : '-'}`);
  }
  if (a.createdMs && Date.now() - a.createdMs > cfg.maxAgeHours * 3600 * 1000) {
    writeNote(p.note, `**Not triaged** — ${a.state} ${a.title} arrived ${Math.round((Date.now() - a.createdMs) / 3600000)}h late (limit ${cfg.maxAgeHours}h).\n`);
    archive(file, p.json);
    return out(`ARCHIVED ${id} stale`);
  }
  try {
    const cwd = await prepare(file, a, cfg, p);
    if (!DRY) fs.writeFileSync(p.attempts, String((Number(readJson(p.attempts)) || 0) + 1));
    try { fs.rmSync(p.verdict); } catch { /* none yet */ }
    return out(`TRIAGE\t${id}\t${p.facts}\t${cwd}`);
  } catch (e) {
    return out(`RETRY ${id} prepare failed: ${String(e.message).split('\n')[0]}`);
  }
}

function toast(title, body) {
  const ps = [
    '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null',
    '$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)',
    '$x = $t.GetElementsByTagName("text")',
    '$x.Item(0).AppendChild($t.CreateTextNode($env:AT_TITLE)) > $null',
    '$x.Item(1).AppendChild($t.CreateTextNode($env:AT_BODY)) > $null',
    '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe").Show([Windows.UI.Notifications.ToastNotification]::new($t))',
  ].join('; ');
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], {
    env: { ...process.env, AT_TITLE: title, AT_BODY: body, WSLENV: `${process.env.WSLENV ? `${process.env.WSLENV}:` : ''}AT_TITLE/u:AT_BODY/u` },
    timeout: 20000, encoding: 'utf8',
  });
  return r.status === 0 ? 'toast ok' : `toast failed (${r.error ? r.error.code : `exit ${r.status}`})`;
}

async function teamsReply(url, payload) {
  try {
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload), signal: AbortSignal.timeout(20000) });
    return `teams reply http ${res.status}`;
  } catch (e) {
    return `teams reply failed (${e.name})`;
  }
}

async function finish(file, cfg) {
  const msg = readJson(file);
  const r = parseAlertMessage(msg);
  if (!r.ok) return out(`FAILED ${path.basename(file)} unparseable`);
  const a = r.alert;
  const p = paths(file, a.id);
  const v = validateVerdict(readJson(p.verdict));
  if (!v.ok) {
    const attempts = Number(readJson(p.attempts)) || 0;
    if (attempts < MAX_ATTEMPTS) return out(`RETRY ${a.id} verdict: ${v.error} (attempt ${attempts}/${MAX_ATTEMPTS})`);
    if (!DRY) fs.appendFileSync(p.note, `\n**Triage failed** after ${attempts} attempts — ${v.error}. Facts: ${path.basename(p.facts)}.\n`);
    archive(file, p.json);
    return out(`FAILED ${a.id} ${v.error}; archived after ${attempts} attempts`);
  }
  const verdict = v.value;
  if (!fs.existsSync(p.note)) writeNote(p.note, `**${a.state}** ${a.title}\n\n${verdict.summary}\n`);
  const sent = [];
  if (verdict.authorityDown) {
    if (DRY) sent.push('dry run: no push, no Teams reply');
    else {
      if (cfg.toast) sent.push(toast('Authority down', pushLine(a, verdict)));
      if (cfg.teamsWebhook) sent.push(await teamsReply(cfg.teamsWebhook, teamsReplyPayload(a, verdict)));
      else sent.push('no teams_webhook configured');
      fs.appendFileSync(p.note, `\n_Notified: ${sent.join('; ')}._\n`);
    }
  }
  archive(file, p.json);
  if (!DRY) { try { fs.rmSync(p.attempts); } catch { /* gone */ } }
  const head = verdict.authorityDown ? `AUTHORITY DOWN: ${verdict.authority} since ${verdict.startIso}${verdict.ongoing ? ' (ongoing)' : ''}` : 'no outage';
  return out(`DONE ${a.id} ${head}${sent.length ? ` [${sent.join('; ')}]` : ''}`);
}

// Route one alert without reading Datadog: everything but a trigger is
// archived, a trigger is POSTed to the routine and archived once accepted.
async function fire(file, cfg) {
  const raw = fs.readFileSync(file, 'utf8');
  let msg = null;
  try { msg = JSON.parse(raw); } catch { /* not JSON */ }
  const id = (msg && msg.id) || path.basename(file, '.json');
  const p = paths(file, id);
  const summary = (msg && (msg.summary || msg.subject)) || '';
  // Dumb on purpose: the title prefix is the whole test. The card is the
  // routine's to read, so a change in Datadog's card never breaks this side.
  if (!summary.startsWith('[Triggered]')) {
    archive(file, p.json);
    return out(`ARCHIVED ${id} not [Triggered]: ${JSON.stringify(summary.slice(0, 60))}`);
  }
  const created = Date.parse(msg.createdDateTime || '');
  if (Number.isFinite(created) && Date.now() - created > cfg.maxAgeHours * 3600 * 1000) {
    writeNote(p.note, `**Not sent** — ${summary} arrived ${Math.round((Date.now() - created) / 3600000)}h late (limit ${cfg.maxAgeHours}h).\n`);
    archive(file, p.json);
    return out(`ARCHIVED ${id} stale`);
  }
  if (!cfg.fireUrl) return out(`RETRY ${id} no alert-triage.fire_url configured`);
  if (!cfg.fireToken) return out(`RETRY ${id} ALERT_TRIAGE_FIRE_TOKEN not set`);
  const text = raw;
  if (DRY) return out(`FIRED ${id} dry-run (${text.length} chars, not sent)`);
  let status = 0; let body = null; let err = null;
  try {
    const res = await fetch(cfg.fireUrl, {
      method: 'POST',
      headers: { Authorization: `Bearer ${cfg.fireToken}`, 'anthropic-version': '2023-06-01', 'anthropic-beta': 'experimental-cc-routine-2026-04-01', 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
      signal: AbortSignal.timeout(30000),
    });
    status = res.status;
    body = await res.text();
  } catch (e) { err = e.name; }
  if (status >= 200 && status < 300) {
    let session = '-';
    try { const j = JSON.parse(body); session = j.claude_code_session_url || j.session_url || j.claude_code_session_id || j.session_id || '-'; } catch { /* not JSON */ }
    writeNote(p.note, `${summary}\n\nSent to the triage routine: ${session}\n`);
    archive(file, p.json);
    try { fs.rmSync(p.attempts); } catch { /* none */ }
    return out(`FIRED ${id} ${session}`);
  }
  const why = err ? `fire failed (${err})` : `fire http ${status}: ${String(body || '').replace(/\s+/g, ' ').slice(0, 200)}`;
  // A network error or a 429/5xx is worth waiting out; anything else counts.
  if (err || status === 429 || status >= 500) return out(`RETRY ${id} ${why}`);
  fs.mkdirSync(p.dir, { recursive: true });
  const attempts = (Number(readJson(p.attempts)) || 0) + 1;
  fs.writeFileSync(p.attempts, String(attempts));
  if (attempts < MAX_ATTEMPTS) return out(`RETRY ${id} ${why} (attempt ${attempts}/${MAX_ATTEMPTS})`);
  writeNote(p.note, `**Not sent** — the routine refused it ${attempts} times: ${why}.\n`);
  archive(file, p.json);
  try { fs.rmSync(p.attempts); } catch { /* gone */ }
  return out(`FAILED ${id} ${why}; archived after ${attempts} attempts`);
}

const [, , cmd, file] = process.argv;
const cfg = loadConfig();
if (cmd === 'config') out(JSON.stringify({ ...cfg, teamsWebhook: cfg.teamsWebhook ? '<set>' : null, fireToken: cfg.fireToken ? '<set>' : null }));
else if (cmd === 'fire' && file) await fire(file, cfg);
else if ((cmd === 'handle' || cmd === 'finish') && file) await (cmd === 'handle' ? handle : finish)(file, cfg);
else { process.stderr.write('usage: alert-triage.mjs fire|handle|finish <alert.json> | config\n'); process.exit(2); }
