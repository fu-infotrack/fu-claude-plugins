#!/usr/bin/env node
// The cloud routine's deterministic side. It reads Datadog through the `pup` CLI
// (DD_ACCESS_TOKEN in the environment): the DBM metrics per (repo, db) pair and
// each candidate's SQL from a DBM query sample. The model does only the
// judgement step, in sub-agents (one investigator per candidate); this script
// does everything else: config, collection, the issue index, the rules, dedup,
// the cap, the reopen gate, filing, the summary and the run state. GitHub is REST only (`gh api`, explicit pages):
// cloud sessions answer GraphQL with 403, their proxy rejects `--paginate`'s
// links, and every path must sit under repos/{owner}/{repo}/ of an attached repo.
//
// Every step prints a status token first; the orchestrator never reads data.
//   node routine.mjs prepare [--live|--observe] '<config-json>'
//   node routine.mjs collect
//   node routine.mjs plan
//   node routine.mjs wait investigate
//   node routine.mjs finish
// The handoff between steps is on disk, in $HOME/.claude/db-sweep/routine/.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  windows, parseConfig, parseCollectorOutput, evaluate, indexIssues, classify, rankFindings,
  composeIssueBody, withDbmPointer, gateDecision, validateVerdict, parseSweepState, buildStateBody,
} from './db-sweep-lib.mjs';
import { collectDb, pupScalar, dbmStatement } from './collect.mjs';

const SCRIPTS = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.dirname(SCRIPTS);
const DIR = path.join(os.homedir(), '.claude', 'db-sweep', 'routine');
const CAP = 5; // new or reopened issues per repo per run
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

// Live runs keep a closed state issue in each repo; with none configured, the
// repo's first live run creates it and says to add its number to CONFIG.
function ensureStateIssue(run, repo) {
  const g = run.repos[repo];
  if (g.state.issue) return { issue: g.state.issue };
  if (run.mode !== 'live' || !g.state.readable) return { issue: null };
  const issue = JSON.parse(gh([`repos/${repo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
    title: 'DB perf sweep routine state', body: buildStateBody(Date.parse(g.spans.window.from)),
  })));
  gh([`repos/${repo}/issues/${issue.number}`, '--method', 'PATCH', '-f', 'state=closed']);
  g.state.issue = issue.number;
  writeJson(f('run.json'), run);
  return { issue: issue.number, created: true };
}

// Post a repo's summary as a comment on its state issue, and (live, complete
// runs only) advance its state marker. Returns note lines to print.
function report(run, repo, summary, { advance }) {
  const g = run.repos[repo];
  const notes = [];
  let st;
  try { st = ensureStateIssue(run, repo); } catch (e) { notes.push(`${repo}: state issue not created (${firstLine(e)})`); st = { issue: null }; }
  if (st.created) notes.push(`${repo}: state issue created #${st.issue} — add "${repo}": ${st.issue} to CONFIG.stateIssues, or every live run creates another`);
  if (!st.issue) {
    notes.push(g.state.readable ? `${repo}: summary not posted (no stateIssues entry)` : `${repo}: summary not posted (state issue unreadable: ${g.state.error})`);
    return notes;
  }
  try {
    gh([`repos/${repo}/issues/${st.issue}/comments`, '--method', 'POST', '--input', '-'], JSON.stringify({ body: summary }));
    notes.push(`${repo}: summary posted to #${st.issue}`);
  } catch (e) { notes.push(`${repo}: summary not posted (${firstLine(e)})`); }
  if (advance && run.mode === 'live' && g.state.readable) {
    try {
      gh([`repos/${repo}/issues/${st.issue}`, '--method', 'PATCH', '--input', '-'], JSON.stringify({ body: buildStateBody(Date.parse(g.spans.window.to)) }));
      notes.push(`${repo}: state advanced to ${g.spans.window.to}`);
    } catch (e) { notes.push(`${repo}: state not advanced (${firstLine(e)}) — the next run reads this window again`); }
  }
  return notes;
}

function block(header, lines) {
  say(`--- ${header} ---`);
  for (const l of lines) say(l);
}

// Each repo is swept on its own: its own state issue, window, summary, cap
// and failure. Pairs share their repo's window.
function prepare(args) {
  const mode = args.includes('--live') ? 'live' : 'observe';
  const cfgArg = args.find((a) => !a.startsWith('--')) || '';
  fs.rmSync(DIR, { recursive: true, force: true });
  fs.mkdirSync(DIR, { recursive: true });
  if (!onPath('gh')) return say('SKIP — gh is not on PATH');
  let cfg;
  try { cfg = parseConfig(cfgArg); } catch (e) { return say(`SKIP — ${e.message}`); }

  const nowMs = Date.now();
  const repoNames = [...new Set(cfg.pairs.map((p) => p.repo))];
  const clones = findClones(repoNames);
  const repos = {};
  const index = {};
  for (const repo of repoNames) {
    const g = { notes: [], skip: null };
    if (!clones[repo]) g.skip = 'not attached to the routine (no clone found)';
    else {
      try { index[repo] = indexIssues(ghPages(`repos/${repo}/issues?state=all&labels=${LABEL}`)); } catch (e) {
        g.skip = `issues unreadable (${firstLine(e)})`;
      }
    }
    const state = g.skip ? { readable: false, issue: null, lastTick: null, error: g.skip } : readState(repo, cfg.stateIssues[repo]);
    g.state = { readable: state.readable, issue: state.issue, error: state.error || null };
    g.spans = windows(state.lastTick, nowMs);
    if (!g.skip) {
      g.notes.push(`window ${g.spans.window.from} → ${g.spans.window.to} vs ${g.spans.baseline.from} → ${g.spans.baseline.to} (${
        state.lastTick ? `since the sweep recorded in #${state.issue}` : state.readable ? 'no stateIssues entry, so the last 7 days' : `state issue unreadable (${state.error}), so the last 7 days`})`);
    }
    repos[repo] = g;
  }
  const pairs = cfg.pairs.map((p, i) => ({
    ...p, id: `p${i}`, sourceDir: clones[p.repo] || null, active: !repos[p.repo].skip,
    outputFile: f(`collect-p${i}.json`),
  }));
  const run = { mode, ddSite: cfg.ddSite, nowIso: new Date(nowMs).toISOString(), pairs, repos, index };
  writeJson(f('run.json'), run);
  const active = pairs.filter((p) => p.active);
  const skipped = repoNames.filter((r) => repos[r].skip).map((r) => `${r}: ${repos[r].skip}`);
  if (!active.length) return say(`SKIP — no (repo, db) pair is reachable: ${skipped.join('; ')}`);

  say(`PROCEED ${active.length} pair(s) ${mode}`);
}

// One output file per active pair: the collected data, or {error} so plan
// fails that pair's repo rather than filing from half the data.
async function collect() {
  if (!fs.existsSync(f('run.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const active = run.pairs.filter((p) => p.active);
  const scalar = onPath('pup') ? pupScalar({ site: run.ddSite, tmpDir: DIR }) : null;
  let ok = 0;
  for (const p of active) {
    const spans = run.repos[p.repo].spans;
    try {
      if (!scalar) throw new Error('pup is not on PATH');
      writeJson(p.outputFile, await collectDb({ db: p.db, window: spans.window, baseline: spans.baseline, drift: spans.drift }, scalar));
      ok++;
    } catch (e) { writeJson(p.outputFile, { error: firstLine(e).slice(0, 300) }); }
  }
  say(`COLLECTED ${ok}/${active.length}`);
}

function summaryText(run, repo, head, lines) {
  const w = run.repos[repo].spans.window;
  return [`## DB perf sweep — ${head}`, '', `Window ${w.from} → ${w.to} (${run.mode}).`, '', ...lines].join('\n');
}

const bullets = (title, xs) => (xs.length ? ['', `### ${title}`, ...xs.map((x) => `- ${x}`)] : []);

// The statement for a query candidate, read from DBM so investigators start
// from the real SQL. Missing it is not fatal: the investigator says so.
async function attachSql(cand) {
  const fd = cand.finding;
  if (!fd.querySignature || !onPath('pup')) return;
  try {
    const s = await dbmStatement({ site: cand.ddSite, signature: fd.querySignature, instance: fd.instance, span: cand.window });
    cand.sql = s?.sql ?? null;
    cand.sqlTables = s?.tables ?? [];
  } catch (e) { cand.sqlError = firstLine(e).slice(0, 300); }
}

async function plan() {
  if (!fs.existsSync(f('run.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const out = [];
  const candidates = [];
  const pending = {};
  let failedRepos = 0;
  let quietRepos = 0;

  for (const [repo, g] of Object.entries(run.repos)) {
    if (g.skip) { out.push(`${repo}: skipped — ${g.skip}`); continue; }
    const pairs = run.pairs.filter((p) => p.repo === repo);

    // One pair failing collection fails its repo: its comparison needs every pair's data.
    const data = {};
    const failures = [];
    for (const p of pairs) {
      let parsed;
      try { parsed = parseCollectorOutput(readJson(p.outputFile), p); } catch (e) { parsed = { ok: false, error: `no output file (${firstLine(e)})` }; }
      if (parsed.ok) data[p.id] = parsed.value; else failures.push(`${p.db}: ${parsed.error}`);
    }
    if (failures.length) {
      failedRepos++;
      out.push(`${repo}: FAILED — ${failures.join('; ')}`);
      out.push(...report(run, repo, summaryText(run, repo, 'FAILED', ['Collection failed, so nothing was filed and this window will be read again next run.', '', ...failures.map((x) => `- ${x}`)]), { advance: false }));
      continue;
    }

    const notes = [...g.notes];
    const perPair = [];
    const counts = { findings: 0, alreadyOpen: 0, accepted: 0 };
    const queue = [];
    for (const p of pairs) {
      const { findings, notes: n } = evaluate(p, data[p.id], g.spans, p.thresholds);
      notes.push(...n.map((x) => `${p.db}: ${x}`));
      counts.findings += findings.length;
      let open = 0;
      for (const fd of findings) {
        const cls = classify(run.index[repo][fd.fingerprint], fd.measure.value, p.thresholds);
        if (cls.kind === 'ALREADY_OPEN') { open++; counts.alreadyOpen++; continue; }
        if (cls.kind === 'ACCEPTED') { counts.accepted++; notes.push(`accepted #${cls.number} stays closed: ${fd.why}`); continue; }
        queue.push({ fd, cls, pair: p });
      }
      perPair.push(`${p.db}: ${data[p.id].instances.length} instance(s), ${data[p.id].queries.length} queries, ${findings.length} finding(s), ${open} already open`);
    }
    const ranked = rankFindings(queue.map((x) => ({ ...x.fd, _x: x }))).map((r) => r._x);
    for (const x of ranked.slice(CAP)) notes.push(`over the ${CAP}-per-repo cap: ${x.fd.severity} ${x.fd.rule} ${x.pair.db} ${x.fd.querySignature || x.fd.table || x.fd.instance} — ${x.fd.why}`);
    const picked = [];
    for (const { fd, cls, pair } of ranked.slice(0, CAP)) {
      const cand = {
        id: fd.fingerprint, repo, db: pair.db, mode: run.mode, classification: cls.kind, number: cls.number ?? null,
        closedAt: cls.closedAt ?? null, recordedValue: cls.recorded ?? null, finding: fd, ddSite: run.ddSite,
        window: g.spans.window, baseline: g.spans.baseline,
        candidateFile: f(`cand-${fd.fingerprint}.json`), outputFile: f(`inv-${fd.fingerprint}.json`), sourceDir: pair.sourceDir,
        sql: null,
      };
      await attachSql(cand);
      writeJson(cand.candidateFile, cand);
      picked.push(cand);
    }
    const line = `${repo}: findings=${counts.findings} already-open=${counts.alreadyOpen} accepted=${counts.accepted} candidates=${picked.length}`;
    out.push(line);
    if (!picked.length) {
      quietRepos++;
      out.push(...report(run, repo, summaryText(run, repo, 'nothing to file', [...perPair.map((x) => `- ${x}`), ...bullets('Notes', notes)]), { advance: true }));
      continue;
    }
    candidates.push(...picked);
    pending[repo] = { candidates: picked.map((c) => c.candidateFile), notes, perPair };
  }

  if (!candidates.length) {
    say(failedRepos ? `FAILED — ${failedRepos} repo(s) failed, ${quietRepos} had nothing to file` : `NO_WORK — ${quietRepos} repo(s) had nothing to file`);
    for (const l of out) say(`  ${l}`);
    return;
  }
  writeJson(f('plan.json'), { repos: pending });
  say(`PROCEED ${candidates.length} — ${Object.keys(pending).length} repo(s) with candidates, ${quietRepos} with nothing to file, ${failedRepos} failed`);
  for (const l of out) say(`  ${l}`);
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

function newBody(c, v) { return withDbmPointer(c.finding, v.body, c.ddSite); }

function labels(c) { return [LABEL, 'auto-filed', `sev:${c.finding.severity}`]; }

function fileOne(c, v) {
  if (c.classification === 'NEW') {
    const issue = JSON.parse(gh([`repos/${c.repo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
      title: v.title, body: composeIssueBody(c.finding, newBody(c, v)), labels: labels(c),
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
  const { repos } = readJson(f('plan.json'));
  const total = { filed: 0, held: 0, dropped: 0, failed: 0 };
  const out = [];
  for (const [repo, { candidates, notes, perPair }] of Object.entries(repos)) {
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
        if (!g.reopen) { n.held++; lines.push(`held #${c.number} (${label}): ${g.reason}`); continue; }
      }
      const action = c.classification === 'NEW' ? 'create' : `reopen #${c.number}`;
      if (run.mode !== 'live') {
        n.filed++;
        lines.push(`would ${action} (${label}) — ${v.title}`);
        drafts.push({ title: `${action}: ${v.title}`, text: c.classification === 'NEW' ? newBody(c, v) : v.comment });
        continue;
      }
      try { lines.push(fileOne(c, v)); n.filed++; } catch (e) {
        n.failed++;
        lines.push(`FAILED ${label}: ${action} failed (${firstLine(e)})`);
        drafts.push({ title: `unfiled: ${v.title}`, text: c.classification === 'NEW' ? newBody(c, v) : v.comment });
      }
    }
    const verb = run.mode === 'live' ? 'filed' : 'would-file';
    const head = `${run.mode === 'live' ? 'SWEPT' : 'OBSERVED'} — ${verb}=${n.filed} held=${n.held} dropped=${n.dropped} failed=${n.failed}`;
    const body = summaryText(run, repo, head, [
      ...perPair.map((x) => `- ${x}`), ...bullets('Candidates', lines), ...bullets('Notes', notes),
      ...drafts.flatMap((d) => ['', `<details><summary>${d.title}</summary>`, '', d.text, '', '</details>']),
    ]);
    // A failed candidate keeps the repo's state where it was, so its next run
    // reads this window again; what this run did file dedups as already open.
    const posted = report(run, repo, body, { advance: !n.failed });
    out.push(`${repo}: ${head}`, ...lines.map((l) => `  ${l}`), ...posted.map((l) => `  ${l}`));
    if (n.failed && run.mode === 'live') out.push(`  ${repo}: state not advanced: ${n.failed} failed`);
    for (const k of Object.keys(total)) total[k] += n[k];
  }
  fs.rmSync(f('plan.json'));
  const verb = run.mode === 'live' ? 'filed' : 'would-file';
  say(`${run.mode === 'live' ? 'SWEPT' : 'OBSERVED'} — ${verb}=${total.filed} held=${total.held} dropped=${total.dropped} failed=${total.failed}`);
  for (const l of out) say(`  ${l}`);
}

// The orchestrator's hand-off is files, not agent notifications: a Haiku
// orchestrator waiting on "completion notifications" ended its turn and never
// ran finish. `wait` blocks until every investigator's output file exists (or
// the timeout), so the next step can always run straight after it.
function wait(stage) {
  if (stage !== 'investigate') {
    process.stderr.write('usage: wait investigate\n');
    process.exit(1);
  }
  if (!fs.existsSync(f('plan.json'))) return say('NOTHING_PENDING');
  const files = Object.values(readJson(f('plan.json')).repos).flatMap((r) => r.candidates).map((cf) => readJson(cf).outputFile);
  const deadline = Date.now() + Number(process.env.DB_SWEEP_WAIT_SECONDS || 540) * 1000;
  const sleeper = new Int32Array(new SharedArrayBuffer(4));
  let missing = files.filter((x) => !fs.existsSync(x));
  while (missing.length && Date.now() < deadline) {
    Atomics.wait(sleeper, 0, 0, 5000);
    missing = files.filter((x) => !fs.existsSync(x));
  }
  if (!missing.length) return say(`READY ${files.length}/${files.length}`);
  say(`TIMEOUT ${files.length - missing.length}/${files.length} — missing: ${missing.map((x) => path.basename(x)).join(', ')}`);
}

const [, , cmd, ...args] = process.argv;
const commands = { prepare: () => prepare(args), collect, plan, finish, wait: () => wait(args[0]) };
if (!commands[cmd]) {
  process.stderr.write(`unknown command: ${cmd}\n`);
  process.exit(1);
}
await commands[cmd]();
