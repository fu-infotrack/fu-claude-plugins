#!/usr/bin/env node
// The cloud routine's deterministic side. Datadog is reachable only through the
// Datadog MCP connector, which only a model can call, so the model does the
// Datadog/judgement steps in sub-agents (one collector per (repo, db) pair, one
// investigator per candidate) and this script does everything else: config,
// the issue index, the rules, dedup, the cap, the reopen gate, filing, the
// summary and the run state. GitHub is REST only (`gh api`, explicit pages):
// cloud sessions answer GraphQL with 403, their proxy rejects `--paginate`'s
// links, and every path must sit under repos/{owner}/{repo}/ of an attached repo.
//
// Every step prints a status token first; the orchestrator never reads data.
//   node routine.mjs prepare [--live|--observe] '<config-json>'
//   node routine.mjs plan
//   node routine.mjs finish
// The handoff between steps is on disk, in $HOME/.claude/db-sweep/routine/.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  windows, parseConfig, parseCollectorOutput, evaluate, indexIssues, classify, rankFindings,
  composeIssueBody, gateDecision, validateVerdict, parseSweepState, buildStateBody,
} from './db-sweep-lib.mjs';

const SCRIPTS = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.dirname(SCRIPTS);
const DIR = path.join(os.homedir(), '.claude', 'db-sweep', 'routine');
const CAP = 5;
const MAX_PAGES = 30;
const LABEL = 'datadog-dbm';

const f = (name) => path.join(DIR, name);
const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const writeJson = (p, v) => fs.writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`);
const say = (line) => process.stdout.write(`${line}\n`);
const firstLine = (e) => String(e?.stderr || e?.message || e).trim().split('\n')[0];

function gh(args, input) {
  return execFileSync('gh', ['api', ...args], {
    encoding: 'utf8', input, maxBuffer: 64 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function ghPages(route) {
  const all = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const items = JSON.parse(gh([`${route}${route.includes('?') ? '&' : '?'}per_page=100&page=${page}`]));
    all.push(...items);
    if (items.length < 100) break;
  }
  return all;
}

function onPath(cmd) {
  try { execFileSync('sh', ['-c', `command -v ${cmd}`], { stdio: 'ignore' }); return true; } catch { return false; }
}

// The routine attaches every target repo; find each clone by its origin URL.
// DB_SWEEP_SEARCH_ROOT narrows the walk (tests; it defaults to the filesystem root).
function findClones(repos) {
  const want = new Map(repos.map((r) => [r.toLowerCase(), r]));
  const out = {};
  const root = process.env.DB_SWEEP_SEARCH_ROOT || '/';
  let found = '';
  try {
    found = execFileSync('find', [root, '-xdev', '-maxdepth', '5', '-name', '.git', '-not', '-path', '*/node_modules/*'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch (e) { found = e.stdout || ''; }
  for (const g of found.split('\n').filter(Boolean)) {
    const dir = path.dirname(g);
    let url = '';
    try { url = execFileSync('git', ['-C', dir, 'config', '--get', 'remote.origin.url'], { encoding: 'utf8' }).trim(); } catch { continue; }
    const m = url.replace(/\/$/, '').replace(/\.git$/, '').match(/[/:]([^/:]+\/[^/:]+)$/);
    const key = m?.[1]?.toLowerCase();
    if (key && want.has(key) && !out[want.get(key)]) out[want.get(key)] = dir;
  }
  return out;
}

function readState(repo, number) {
  if (number === undefined) return { readable: true, issue: null, lastTick: null };
  try {
    const state = parseSweepState(JSON.parse(gh([`repos/${repo}/issues/${number}`])).body);
    if (!state) return { readable: false, issue: null, lastTick: null, error: `#${number} holds no state marker` };
    return { readable: true, issue: number, lastTick: state.last_successful_tick };
  } catch (e) { return { readable: false, issue: null, lastTick: null, error: firstLine(e) }; }
}

// Live runs keep a closed state issue; with none configured, the first live
// run creates it and says to add its number to CONFIG.
function ensureStateIssue(run) {
  if (run.state.issue) return { issue: run.state.issue };
  if (run.mode !== 'live' || !run.state.readable) return { issue: null };
  const issue = JSON.parse(gh([`repos/${run.stateRepo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
    title: 'DB perf sweep routine state', body: buildStateBody(Date.parse(run.spans.window.from)),
  })));
  gh([`repos/${run.stateRepo}/issues/${issue.number}`, '--method', 'PATCH', '-f', 'state=closed']);
  run.state.issue = issue.number;
  writeJson(f('run.json'), run);
  return { issue: issue.number, created: true };
}

// Post the run summary as a comment on the state issue, and (live, complete
// runs only) advance the state marker. Returns note lines to print.
function report(run, summary, { advance }) {
  const notes = [];
  let st;
  try { st = ensureStateIssue(run); } catch (e) { notes.push(`state issue not created (${firstLine(e)})`); st = { issue: null }; }
  if (st.created) notes.push(`state issue created: ${run.stateRepo}#${st.issue} — add "stateIssue": ${st.issue} to the routine's CONFIG, or every live run creates another`);
  if (!st.issue) {
    notes.push(run.state.readable ? 'summary not posted: no stateIssue in CONFIG' : `summary not posted: state issue unreadable (${run.state.error})`);
    return notes;
  }
  try {
    gh([`repos/${run.stateRepo}/issues/${st.issue}/comments`, '--method', 'POST', '--input', '-'], JSON.stringify({ body: summary }));
    notes.push(`summary posted to ${run.stateRepo}#${st.issue}`);
  } catch (e) { notes.push(`summary not posted (${firstLine(e)})`); }
  if (advance && run.mode === 'live' && run.state.readable) {
    try {
      gh([`repos/${run.stateRepo}/issues/${st.issue}`, '--method', 'PATCH', '--input', '-'], JSON.stringify({ body: buildStateBody(Date.parse(run.spans.window.to)) }));
      notes.push(`state advanced to ${run.spans.window.to}`);
    } catch (e) { notes.push(`state not advanced (${firstLine(e)}) — the next run reads this window again`); }
  }
  return notes;
}

function block(header, lines) {
  say(`--- ${header} ---`);
  for (const l of lines) say(l);
}

function renderQuery(db, spans) {
  const tpl = fs.readFileSync(path.join(PLUGIN, 'collector-query.js'), 'utf8');
  const params = `const PARAMS = ${JSON.stringify({ db, window: spans.window, baseline: spans.baseline, drift: spans.drift })};`;
  return tpl.replace(/^const PARAMS = .*$/m, params);
}

function prepare(args) {
  const mode = args.includes('--live') ? 'live' : 'observe';
  const cfgArg = args.find((a) => !a.startsWith('--')) || '';
  fs.rmSync(DIR, { recursive: true, force: true });
  fs.mkdirSync(DIR, { recursive: true });
  if (!onPath('gh')) return say('SKIP — gh is not on PATH');
  let cfg;
  try { cfg = parseConfig(cfgArg); } catch (e) { return say(`SKIP — ${e.message}`); }

  const nowMs = Date.now();
  const state = readState(cfg.stateRepo, cfg.stateIssue);
  const spans = windows(state.lastTick, nowMs);
  const notes = [`window ${spans.window.from} → ${spans.window.to} vs ${spans.baseline.from} → ${spans.baseline.to} (${
    state.lastTick ? `since the sweep recorded in #${state.issue}` : state.readable ? 'no stateIssue in CONFIG, so the last 7 days' : `state issue unreadable (${state.error}), so the last 7 days`})`];

  const repos = [...new Set(cfg.pairs.map((p) => p.repo))];
  const clones = findClones(repos);
  const index = {};
  const skipped = [];
  for (const repo of repos) {
    if (!clones[repo]) { skipped.push(`${repo}: not attached to the routine (no clone found)`); continue; }
    try { index[repo] = indexIssues(ghPages(`repos/${repo}/issues?state=all&labels=${LABEL}`)); } catch (e) {
      skipped.push(`${repo}: issues unreadable (${firstLine(e)})`);
    }
  }
  const pairs = cfg.pairs.map((p, i) => ({
    ...p, id: `p${i}`, sourceDir: clones[p.repo] || null, active: Boolean(index[p.repo]),
    queryFile: f(`query-p${i}.js`), outputFile: f(`collect-p${i}.json`),
  }));
  for (const p of pairs.filter((x) => !x.active)) notes.push(`skipped ${p.repo} ${p.db} — ${skipped.find((s) => s.startsWith(`${p.repo}:`)).split(': ').slice(1).join(': ')}`);
  const active = pairs.filter((p) => p.active);

  const run = {
    mode, stateRepo: cfg.stateRepo, ddSite: cfg.ddSite, spans, nowIso: new Date(nowMs).toISOString(), pairs, index, notes,
    state: { readable: state.readable, issue: state.issue, error: state.error || null },
  };
  writeJson(f('run.json'), run);
  if (!active.length) return say(`SKIP — no (repo, db) pair is reachable: ${skipped.join('; ')}`);

  for (const p of active) fs.writeFileSync(p.queryFile, renderQuery(p.db, spans));
  say(`PROCEED ${active.length} collectors ${mode}`);
  for (const p of active) {
    block(`collector ${p.id} ${p.db}`, [
      `Read ${path.join(PLUGIN, 'routine-collector.md')} and follow it exactly. Your inputs:`,
      '',
      `DB=${p.db}`,
      `QUERY_FILE=${p.queryFile}`,
      `OUTPUT_FILE=${p.outputFile}`,
    ]);
  }
}

function summaryText(run, head, lines) {
  return [`## DB perf sweep — ${head}`, '', `Window ${run.spans.window.from} → ${run.spans.window.to} (${run.mode}).`, '', ...lines].join('\n');
}

function plan() {
  if (!fs.existsSync(f('run.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const active = run.pairs.filter((p) => p.active);

  // Any collector failing fails the run: the comparison needs every pair's data.
  const data = {};
  const failures = [];
  for (const p of active) {
    let parsed;
    try { parsed = parseCollectorOutput(readJson(p.outputFile), p); } catch (e) { parsed = { ok: false, error: `no output file (${firstLine(e)})` }; }
    if (parsed.ok) data[p.id] = parsed.value; else failures.push(`${p.repo} ${p.db}: ${parsed.error}`);
  }
  if (failures.length) {
    const notes = report(run, summaryText(run, 'FAILED', ['Collection failed, so nothing was filed and the window will be read again next run.', '', ...failures.map((x) => `- ${x}`)]), { advance: false });
    say(`FAILED — ${failures.length} collector(s) failed; nothing filed, state not advanced`);
    for (const l of [...failures, ...notes]) say(`  ${l}`);
    return;
  }

  const notes = [...run.notes];
  const counts = { findings: 0, alreadyOpen: 0, accepted: 0 };
  const perPair = [];
  const queue = [];
  for (const p of active) {
    const { findings, notes: n } = evaluate(p, data[p.id], run.spans, p.thresholds);
    notes.push(...n.map((x) => `${p.db}: ${x}`));
    counts.findings += findings.length;
    let open = 0;
    for (const fd of findings) {
      const cls = classify(run.index[p.repo][fd.fingerprint], fd.measure.value, p.thresholds);
      if (cls.kind === 'ALREADY_OPEN') { open++; counts.alreadyOpen++; continue; }
      if (cls.kind === 'ACCEPTED') { counts.accepted++; notes.push(`accepted #${cls.number} stays closed: ${fd.why}`); continue; }
      queue.push({ fd, cls, pair: p });
    }
    perPair.push(`${p.repo} ${p.db}: ${data[p.id].instances.length} instance(s), ${data[p.id].queries.length} queries, ${findings.length} finding(s), ${open} already open`);
  }

  const ranked = rankFindings(queue.map((x) => ({ ...x.fd, _x: x }))).map((r) => r._x);
  const picked = ranked.slice(0, CAP);
  for (const x of ranked.slice(CAP)) notes.push(`over the ${CAP}-per-run cap: ${x.fd.severity} ${x.fd.rule} ${x.pair.db} ${x.fd.querySignature || x.fd.table || x.fd.instance} — ${x.fd.why}`);

  const candidates = picked.map(({ fd, cls, pair }) => {
    const id = fd.fingerprint;
    const cand = {
      id, repo: pair.repo, db: pair.db, mode: run.mode, classification: cls.kind, number: cls.number ?? null,
      closedAt: cls.closedAt ?? null, recordedValue: cls.recorded ?? null, finding: fd, ddSite: run.ddSite,
      window: run.spans.window, baseline: run.spans.baseline,
      candidateFile: f(`cand-${id}.json`), outputFile: f(`inv-${id}.json`), sourceDir: pair.sourceDir,
    };
    writeJson(cand.candidateFile, cand);
    return cand;
  });
  writeJson(f('plan.json'), { candidates: candidates.map((c) => c.candidateFile), notes, perPair, counts });

  const summary = `findings=${counts.findings} already-open=${counts.alreadyOpen} accepted=${counts.accepted} candidates=${candidates.length}`;
  if (!candidates.length) {
    const posted = report(run, summaryText(run, 'nothing to file', [...perPair.map((x) => `- ${x}`), ...(notes.length ? ['', '### Notes', ...notes.map((x) => `- ${x}`)] : [])]), { advance: true });
    say(`NO_WORK — ${summary}`);
    for (const l of [...perPair, ...notes, ...posted]) say(`  ${l}`);
    return;
  }
  say(`PROCEED ${candidates.length} — ${summary}`);
  for (const c of candidates) {
    block(`investigator ${c.id}`, [
      `Read ${path.join(PLUGIN, 'routine-investigator.md')} and follow it exactly. Your inputs:`,
      '',
      `CANDIDATE_FILE=${c.candidateFile}`,
      `OUTPUT_FILE=${c.outputFile}`,
      `SOURCE_DIR=${c.sourceDir}`,
    ]);
  }
}

// The reopen gate's inputs: the fix commit on the issue's close event, then
// compare it with the deployed commit; with no fix commit, the deployed
// commit's date against the close.
function gate(c, deployedSha) {
  if (!deployedSha) return gateDecision({ deployedSha });
  let fixSha = null;
  try {
    const events = ghPages(`repos/${c.repo}/issues/${c.number}/events`);
    fixSha = [...events].reverse().find((e) => e.event === 'closed')?.commit_id || null;
  } catch { /* fall through to the date check */ }
  try {
    if (fixSha) {
      const cmp = JSON.parse(gh([`repos/${c.repo}/compare/${fixSha}...${deployedSha}`]));
      return gateDecision({ deployedSha, compareStatus: cmp.status });
    }
    const commit = JSON.parse(gh([`repos/${c.repo}/commits/${deployedSha}`]));
    return gateDecision({ deployedSha, deployedCommitDate: commit.commit?.committer?.date, closedAt: c.closedAt });
  } catch (e) { return { reopen: false, reason: `cannot tell whether the fix is deployed (${firstLine(e)})` }; }
}

function labels(c) { return [LABEL, 'auto-filed', `sev:${c.finding.severity}`]; }

function fileOne(c, v) {
  if (c.classification === 'NEW') {
    const issue = JSON.parse(gh([`repos/${c.repo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
      title: v.title, body: composeIssueBody(c.finding, v.body), labels: labels(c),
    })));
    return `${c.repo}#${issue.number} created (${c.finding.severity}) — ${v.title}`;
  }
  gh([`repos/${c.repo}/issues/${c.number}`, '--method', 'PATCH', '-f', 'state=open']);
  gh([`repos/${c.repo}/issues/${c.number}/comments`, '--method', 'POST', '--input', '-'], JSON.stringify({ body: v.comment }));
  return `${c.repo}#${c.number} reopened (${c.finding.severity}) — ${v.title}`;
}

function finish() {
  if (!fs.existsSync(f('plan.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const { candidates, notes, perPair } = readJson(f('plan.json'));
  const n = { filed: 0, held: 0, dropped: 0, failed: 0 };
  const lines = [];
  const drafts = [];
  for (const cf of candidates) {
    const c = readJson(cf);
    const label = `${c.finding.severity} ${c.finding.rule} ${c.db} ${c.finding.querySignature || c.finding.table || c.finding.instance}`;
    let res;
    try { res = validateVerdict(readJson(c.outputFile), c.classification); } catch (e) { res = { ok: false, error: `no verdict file (${firstLine(e)})` }; }
    if (!res.ok) { n.failed++; lines.push(`FAILED ${label}: ${res.error}`); continue; }
    const v = res.value;
    if (!v.actionable) { n.dropped++; lines.push(`dropped ${label}: ${v.reason}`); continue; }
    if (c.classification === 'REGRESSION_CHECK') {
      const g = gate(c, v.deployedSha);
      if (!g.reopen) { n.held++; lines.push(`held ${c.repo}#${c.number} (${label}): ${g.reason}`); continue; }
    }
    const action = c.classification === 'NEW' ? `create in ${c.repo}` : `reopen ${c.repo}#${c.number}`;
    if (run.mode !== 'live') {
      n.filed++;
      lines.push(`would ${action} (${label}) — ${v.title}`);
      drafts.push({ title: `${action}: ${v.title}`, text: c.classification === 'NEW' ? v.body : v.comment });
      continue;
    }
    try { lines.push(fileOne(c, v)); n.filed++; } catch (e) {
      n.failed++;
      lines.push(`FAILED ${label}: ${action} failed (${firstLine(e)})`);
      drafts.push({ title: `unfiled: ${v.title}`, text: c.classification === 'NEW' ? v.body : v.comment });
    }
  }
  const verb = run.mode === 'live' ? 'filed' : 'would-file';
  const head = `${run.mode === 'live' ? 'SWEPT' : 'OBSERVED'} — ${verb}=${n.filed} held=${n.held} dropped=${n.dropped} failed=${n.failed}`;
  const body = summaryText(run, head, [
    ...perPair.map((x) => `- ${x}`), '', '### Candidates', ...lines.map((x) => `- ${x}`),
    ...(notes.length ? ['', '### Notes', ...notes.map((x) => `- ${x}`)] : []),
    ...drafts.flatMap((d) => ['', `<details><summary>${d.title}</summary>`, '', d.text, '', '</details>']),
  ]);
  // A failed candidate keeps the state where it was, so the next run reads this
  // window again; what this run did file dedups as already open there.
  const posted = report(run, body, { advance: !n.failed });
  fs.rmSync(f('plan.json'));
  say(head);
  for (const l of [...lines, ...notes, ...posted, ...(n.failed && run.mode === 'live' ? [`state not advanced: ${n.failed} failed`] : [])]) say(`  ${l}`);
}

const [, , cmd, ...args] = process.argv;
const commands = { prepare: () => prepare(args), plan, finish };
if (!commands[cmd]) {
  process.stderr.write(`unknown command: ${cmd}\n`);
  process.exit(1);
}
commands[cmd]();
