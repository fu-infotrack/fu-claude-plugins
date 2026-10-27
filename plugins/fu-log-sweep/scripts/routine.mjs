#!/usr/bin/env node
// The cloud routine's deterministic side, for every repo in its config. It reads
// Datadog through the `pup` CLI (DD_ACCESS_TOKEN in the environment): the error
// buckets and their samples (collect.mjs), and a regression's per-version counts.
// The model does only the judgement step, in sub-agents (one investigator per
// candidate); this script does everything else: config, collection, the GitHub
// issue index, signatures, dedup, the release gate, the caps, filing and the run
// state. GitHub is REST only (`gh api`, explicit pages): cloud sessions answer
// GraphQL with 403, their proxy rejects `--paginate`'s links, and every path
// must sit under repos/{owner}/{repo}/ of an attached repo.
//
// Every step prints a status token first; the orchestrator never reads data.
//   node routine.mjs prepare [--live|--observe] '<config-json>'
//   node routine.mjs collect
//   node routine.mjs plan
//   node routine.mjs wait investigate
//   node routine.mjs finish
// The handoff between steps is on disk, in $HOME/.claude/log-sweep/routine/.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  windowStartMs, classify, buildTitle, buildSignature, releaseCheck,
  parseCollectorOutput, issueMatchesBySig, buildBucketQuery,
  validateInvestigation, composeIssueBody, parseSweepState, buildStateBody,
} from './log-sweep-lib.mjs';
import { pupRunner, collectRepo, bucketVersions } from './collect.mjs';

const SCRIPTS = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.dirname(SCRIPTS);
const DIR = path.join(os.homedir(), '.claude', 'log-sweep', 'routine');
const BUCKET_CAP = 20; // per repo, before sampling
const SURVIVOR_CAP = 10; // per repo per run
const MAX_PAGES = 30;
const DEFAULT_SITE = 'https://ap2.datadoghq.com';

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

// Every page of a REST list, 100 at a time; throws if any page fails.
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
// LOG_SWEEP_SEARCH_ROOT narrows the walk (tests; it defaults to the filesystem root).
function findClones(repos) {
  const want = new Map(repos.map((r) => [r.toLowerCase(), r]));
  const out = {};
  let found = '';
  try {
    found = execFileSync('find', [process.env.LOG_SWEEP_SEARCH_ROOT || '/', '-xdev', '-maxdepth', '5', '-name', '.git', '-not', '-path', '*/node_modules/*'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch (e) { found = e.stdout || ''; }
  for (const g of found.split('\n').filter(Boolean)) {
    const dir = path.dirname(g);
    let url = '';
    try { url = execFileSync('git', ['-C', dir, 'config', '--get', 'remote.origin.url'], { encoding: 'utf8' }).trim(); } catch { continue; }
    const key = url.replace(/\/$/, '').replace(/\.git$/, '').match(/[/:]([^/:]+\/[^/:]+)$/)?.[1]?.toLowerCase();
    if (key && want.has(key) && !out[want.get(key)]) out[want.get(key)] = dir;
  }
  return out;
}

// {repos: [{repo, ...log-sweep keys}], stateIssues: {repo: n}, ddSite}. Any
// other top-level key is a default for every repo; a repo's own keys win.
function parseConfig(text) {
  let cfg;
  try { cfg = JSON.parse(text || ''); } catch { throw new Error('CONFIG is not JSON'); }
  if (!cfg || !Array.isArray(cfg.repos) || !cfg.repos.length) throw new Error('CONFIG needs a non-empty "repos" array');
  const { repos, stateIssues = {}, ddSite = DEFAULT_SITE, ...defaults } = cfg;
  const seen = new Set();
  for (const [i, r] of repos.entries()) {
    if (!r || typeof r.repo !== 'string' || !/^[^/\s]+\/[^/\s]+$/.test(r.repo)) throw new Error(`repos[${i}] needs "repo": "<owner>/<name>"`);
    if (seen.has(r.repo.toLowerCase())) throw new Error(`${r.repo} is listed twice`);
    seen.add(r.repo.toLowerCase());
  }
  if (typeof stateIssues !== 'object' || Array.isArray(stateIssues)) throw new Error('"stateIssues" must map repo → issue number');
  return { repos: repos.map((r) => ({ logsUrlBase: `${ddSite.replace(/\/$/, '')}/logs?query=`, ...defaults, ...r })), stateIssues, ddSite };
}

// The state issue is the config's number for the repo, read by one repo-scoped
// GET: the cloud proxy refuses every path outside repos/{owner}/{repo}/, so it
// cannot be searched for. Only its author or a maintainer can edit its body, so
// the configured number is what makes it trusted. `readable: false` when the
// read fails or the issue holds no state marker (a mistyped number) — then
// nothing writes, so an unrelated issue's body is never overwritten.
function readState(repo, number) {
  if (number === undefined) return { readable: true, issue: null, lastTick: null };
  const unreadable = (error) => ({ readable: false, issue: null, lastTick: null, error });
  if (!Number.isInteger(number) || number < 1) return unreadable(`stateIssues entry must be an issue number, not ${JSON.stringify(number)}`);
  try {
    const state = parseSweepState(JSON.parse(gh([`repos/${repo}/issues/${number}`])).body);
    if (!state) return unreadable(`#${number} holds no state marker`);
    return { readable: true, issue: number, lastTick: state.last_successful_tick };
  } catch (e) { return unreadable(firstLine(e)); }
}

// Record a repo's completed live sweep as ending at this run's window end.
// Returns the note to print.
function saveState(run, g) {
  if (run.mode !== 'live') return null;
  if (!g.state.readable) return `${g.repo}: state not saved: the state issue was unreadable at prepare`;
  const body = buildStateBody(Date.parse(run.nowIso));
  try {
    if (g.state.issue) {
      gh([`repos/${g.repo}/issues/${g.state.issue}`, '--method', 'PATCH', '--input', '-'], JSON.stringify({ body }));
      return `${g.repo}: state saved to #${g.state.issue}`;
    }
    const issue = JSON.parse(gh([`repos/${g.repo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
      title: 'log-sweep routine state', body,
    })));
    gh([`repos/${g.repo}/issues/${issue.number}`, '--method', 'PATCH', '-f', 'state=closed']);
    return `${g.repo}: state saved to new issue #${issue.number} — add "${g.repo}": ${issue.number} to CONFIG.stateIssues, or every live run creates another`;
  } catch (e) { return `${g.repo}: state not saved (${firstLine(e)}) — the next run sweeps the same window again`; }
}

function block(header, lines) {
  say(`--- ${header} ---`);
  for (const l of lines) say(l);
}

// Each repo is swept on its own: its own config, state issue, window, caps and
// failure. A repo that cannot be prepared is skipped and named; the rest carry on.
function prepare(args) {
  const mode = args.includes('--live') ? 'live' : 'observe';
  const cfgArg = args.find((a) => !a.startsWith('--')) || '';
  fs.rmSync(DIR, { recursive: true, force: true });
  fs.mkdirSync(DIR, { recursive: true });
  if (!onPath('gh')) return say('SKIP — gh is not on PATH');
  let cfg;
  try { cfg = parseConfig(cfgArg); } catch (e) { return say(`SKIP — ${e.message}`); }

  const nowMs = Date.now();
  const clones = findClones(cfg.repos.map((r) => r.repo));
  const repos = cfg.repos.map((entry, i) => {
    const g = { id: `r${i}`, repo: entry.repo, skip: null, notes: [], outputFile: f(`collect-r${i}.json`) };
    const skip = (why) => { g.skip = why; return g; };
    if (!clones[entry.repo]) return skip('not attached to the routine (no clone found)');
    g.sourceDir = clones[entry.repo];

    let c;
    try {
      c = JSON.parse(execFileSync(process.execPath, [path.join(SCRIPTS, 'sweep.mjs'), 'resolve', JSON.stringify(entry)], { cwd: g.sourceDir, encoding: 'utf8' }));
    } catch (e) { return skip(`config did not resolve: ${firstLine(e)}`); }
    if (!c.query) return skip('no services (no k8_settings app_name in its clone and no "services" in its config)');

    const state = readState(entry.repo, cfg.stateIssues[entry.repo]);
    g.state = { readable: state.readable, issue: state.issue };
    const startMs = windowStartMs(state.lastTick, nowMs);
    g.notes.push(`window ${new Date(startMs).toISOString()} → ${new Date(nowMs).toISOString()} (${
      state.lastTick ? `since the sweep recorded in #${state.issue}`
        : state.readable ? 'no stateIssues entry, so the last 24h'
          : `state issue unreadable (${state.error}), so the last 24h`})`);

    let issues;
    try { issues = ghPages(`repos/${entry.repo}/issues?state=all&labels=datadog-logs`); } catch (e) {
      return skip(`could not list its datadog-logs issues, so nothing can be deduped: ${firstLine(e)}`);
    }
    g.releases = [];
    try {
      g.releases = JSON.parse(gh([`repos/${entry.repo}/releases?per_page=30`])).map((r) => ({ tag: r.tag_name, publishedAt: r.published_at }));
    } catch (e) { g.notes.push(`release gate off (releases unreadable: ${firstLine(e)}) — regressions reopen`); }

    Object.assign(g, {
      env: c.env, query: c.query, statusQuery: c.statusQuery, errorFacet: c.errorFacet, stackPath: c.stackPath,
      messagePath: c.messagePath, versionTag: c.versionTag, appNamespace: c.appNamespace, logsUrlBase: c.logsUrlBase,
      threshold: Number(c.count ?? c.count_threshold ?? c.countThreshold ?? 1),
      startIso: new Date(startMs).toISOString(), matches: issueMatchesBySig(issues),
    });
    return g;
  });
  writeJson(f('run.json'), { mode, ddSite: cfg.ddSite, nowIso: new Date(nowMs).toISOString(), repos });

  const active = repos.filter((g) => !g.skip);
  const skipped = repos.filter((g) => g.skip).map((g) => `${g.repo}: skipped — ${g.skip}`);
  if (!active.length) return say(`SKIP — no repo is reachable: ${skipped.join('; ')}`);
  say(`PROCEED ${active.length} repo(s) ${mode}`);
  for (const l of skipped) say(`  ${l}`);
}

// One output file per active repo: its buckets, or {error} so plan fails that
// repo rather than deduping against half the data.
async function collect() {
  if (!fs.existsSync(f('run.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const active = run.repos.filter((g) => !g.skip);
  const pup = onPath('pup') ? pupRunner({ site: run.ddSite, retryMs: Number(process.env.LOG_SWEEP_RETRY_MS || 5000) }) : null;
  let ok = 0;
  for (const g of active) {
    try {
      if (!pup) throw new Error('pup is not on PATH');
      writeJson(g.outputFile, await collectRepo({
        query: g.query, env: g.env, statusQuery: g.statusQuery, errorFacet: g.errorFacet, stackPath: g.stackPath,
        messagePath: g.messagePath, from: g.startIso, to: run.nowIso, threshold: g.threshold, cap: BUCKET_CAP,
      }, pup));
      ok++;
    } catch (e) { writeJson(g.outputFile, { error: firstLine(e).slice(0, 300) }); }
  }
  say(`COLLECTED ${ok}/${active.length}`);
}

async function plan() {
  if (!fs.existsSync(f('run.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const pup = onPath('pup') ? pupRunner({ site: run.ddSite, retryMs: Number(process.env.LOG_SWEEP_RETRY_MS || 5000) }) : null;
  const out = [];
  const candidates = [];
  const pending = {};
  let failed = 0;
  let quiet = 0;

  for (const g of run.repos) {
    if (g.skip) { out.push(`${g.repo}: skipped — ${g.skip}`); continue; }
    let raw;
    let parsed;
    try { raw = readJson(g.outputFile); parsed = raw.error ? { ok: false, error: raw.error } : parseCollectorOutput(raw); } catch (e) {
      parsed = { ok: false, error: `no output file (${firstLine(e)})` };
    }
    if (!parsed.ok) {
      failed++;
      out.push(`${g.repo}: FAILED — collection failed (${parsed.error}); nothing filed, state kept`);
      continue;
    }

    const notes = [...g.notes];
    const total = raw.total ?? parsed.buckets.length;
    if (total > parsed.buckets.length) notes.push(`${total - parsed.buckets.length} bucket(s) under the threshold or over the ${BUCKET_CAP}-bucket cap`);
    let alreadyOpen = 0;
    const survivors = [];
    for (const b of parsed.buckets) {
      const sample = b.samples[0];
      if (!sample) { notes.push(`no sample for ${b.service} ${b.errorKind} (×${b.count}), so no signature; skipped this run`); continue; }
      const { sig, frame, confidence } = buildSignature(b.errorKind, b.service, sample.stack, sample.message, g.appNamespace);
      const matches = g.matches[sig] || [];
      const cls = classify(matches);
      if (cls.kind === 'ALREADY_OPEN') { alreadyOpen++; continue; }
      const bucketQuery = buildBucketQuery(b.service, g.env, g.statusQuery, g.errorFacet, b.errorKind);
      let release = null;
      if (cls.kind === 'REGRESSION') {
        let versions = [];
        try {
          if (!pup) throw new Error('pup is not on PATH');
          versions = await bucketVersions({ bucketQuery, versionTag: g.versionTag, from: g.startIso, to: run.nowIso }, pup);
        } catch (e) { notes.push(`${sig}: versions unreadable (${firstLine(e)}) — reopens without the release gate`); }
        b.versions = versions;
        const closedAt = matches.find((m) => m.number === cls.number)?.closedAt;
        release = releaseCheck(versions, g.releases, Date.parse(closedAt));
        if (!release.regressed) {
          notes.push(`held ${sig} #${cls.number}: fix not in prod yet (still on ${release.preFixVersions.join(', ')})`);
          continue;
        }
      }
      survivors.push({ b, sample, sig, frame, confidence, cls, release, bucketQuery });
    }
    survivors.sort((x, y) => y.b.count - x.b.count);
    if (survivors.length > SURVIVOR_CAP) notes.push(`dropped ${survivors.length - SURVIVOR_CAP} candidates over the ${SURVIVOR_CAP}-per-repo cap`);

    const picked = survivors.slice(0, SURVIVOR_CAP).map(({ b, sample, sig, frame, confidence, cls, release, bucketQuery }) => {
      const errorMessage = (sample.message || '').split('\n')[0];
      const cand = {
        sig, repo: g.repo, mode: run.mode, classification: cls.kind, number: cls.number ?? null,
        errorKind: b.errorKind, service: b.service, env: g.env, count: b.count, frame, confidence,
        errorMessage, lastSeenIso: sample.timestamp || null, windowStartIso: g.startIso, windowEndIso: run.nowIso,
        title: buildTitle(b.errorKind, frame || errorMessage), bucketQuery, stackPath: g.stackPath, ddSite: run.ddSite,
        logsUrl: g.logsUrlBase ? `${g.logsUrlBase}${encodeURIComponent(bucketQuery)}` : null,
        postFixCount: release?.postFixCount ?? null, versions: b.versions,
        candidateFile: f(`cand-${g.id}-${sig}.json`), sampleFile: f(`sample-${g.id}-${sig}.json`), outputFile: f(`inv-${g.id}-${sig}.json`),
        sourceDir: g.sourceDir,
      };
      writeJson(cand.candidateFile, cand);
      writeJson(cand.sampleFile, b.samples);
      return cand;
    });

    out.push(`${g.repo}: buckets=${total} kept=${parsed.buckets.length} already-open=${alreadyOpen} candidates=${picked.length}`);
    if (!picked.length) {
      quiet++;
      const saved = saveState(run, g);
      out.push(...notes.map((n) => `  ${n}`), ...(saved ? [`  ${saved}`] : []));
      continue;
    }
    candidates.push(...picked);
    pending[g.id] = { candidates: picked.map((c) => c.candidateFile), notes };
  }

  if (!candidates.length) {
    say(failed ? `FAILED — ${failed} repo(s) failed, ${quiet} had nothing to file` : `NO_WORK — ${quiet} repo(s) had nothing to file`);
    for (const l of out) say(`  ${l}`);
    return;
  }
  writeJson(f('plan.json'), { repos: pending });
  say(`PROCEED ${candidates.length} — ${Object.keys(pending).length} repo(s) with candidates, ${quiet} with nothing to file, ${failed} failed`);
  for (const l of out) say(`  ${l}`);
  for (const c of candidates) {
    block(`investigator ${c.sig}`, [
      `Read ${path.join(PLUGIN, 'routine-investigator.md')} and follow it exactly. Your inputs:`,
      '',
      `CANDIDATE_FILE=${c.candidateFile}`,
      `SAMPLE_FILE=${c.sampleFile}`,
      `OUTPUT_FILE=${c.outputFile}`,
      `SOURCE_DIR=${c.sourceDir}`,
    ]);
  }
}

function fileOne(c, v) {
  if (c.classification === 'NEW') {
    const issue = JSON.parse(gh([`repos/${c.repo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
      title: c.title, body: composeIssueBody(c.sig, v.body), labels: ['datadog-logs', 'auto-filed', `sev:${v.severity}`],
    })));
    return `#${issue.number} created (${v.severity}) — ${c.title}`;
  }
  gh([`repos/${c.repo}/issues/${c.number}`, '--method', 'PATCH', '-f', 'state=open']);
  gh([`repos/${c.repo}/issues/${c.number}/comments`, '--method', 'POST', '--input', '-'], JSON.stringify({ body: v.comment }));
  return `#${c.number} reopened (${v.severity}) — ${c.title}`;
}

function finish() {
  if (!fs.existsSync(f('plan.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const { repos } = readJson(f('plan.json'));
  const total = { filed: 0, dropped: 0, failed: 0 };
  const out = [];
  const verb = run.mode === 'live' ? 'filed' : 'would-file';
  for (const [id, { candidates, notes }] of Object.entries(repos)) {
    const g = run.repos.find((x) => x.id === id);
    const n = { filed: 0, dropped: 0, failed: 0 };
    const lines = [];
    for (const cf of candidates) {
      const c = readJson(cf);
      let res;
      try { res = validateInvestigation(readJson(c.outputFile), c.classification); } catch (e) { res = { ok: false, error: `no verdict file (${firstLine(e)})` }; }
      if (!res.ok) { n.failed++; lines.push(`FAILED ${c.sig} ${c.service} ${c.errorKind}: ${res.error}`); continue; }
      const v = res.value;
      if (!v.actionable) { n.dropped++; lines.push(`dropped ${c.sig} ${c.service} ${c.errorKind}: ${v.reason}`); continue; }
      const action = c.classification === 'NEW' ? 'create' : `reopen #${c.number}`;
      if (run.mode !== 'live') { n.filed++; lines.push(`would ${action} (${v.severity}) ${c.sig} ×${c.count} — ${c.title} — ${v.reason}`); continue; }
      try { lines.push(fileOne(c, v)); n.filed++; } catch (e) {
        n.failed++;
        lines.push(`FAILED ${c.sig}: ${action} failed (${firstLine(e)}) — drafted body follows`, v.body, ...(v.comment ? ['--- comment ---', v.comment] : []));
      }
    }
    // A failed candidate keeps the repo's state, so its next run sweeps this
    // window again; what this run did file dedups as already open there.
    const saved = n.failed && run.mode === 'live'
      ? `${g.repo}: state not saved: ${n.failed} failed — the next run sweeps this window again`
      : saveState(run, g);
    out.push(`${g.repo}: ${verb}=${n.filed} dropped=${n.dropped} failed=${n.failed}`, ...[...lines, ...notes, ...(saved ? [saved] : [])].map((l) => `  ${l}`));
    for (const k of Object.keys(total)) total[k] += n[k];
  }
  fs.rmSync(f('plan.json'));
  say(`${run.mode === 'live' ? 'SWEPT' : 'OBSERVED'} — ${verb}=${total.filed} dropped=${total.dropped} failed=${total.failed}`);
  for (const l of out) say(`  ${l}`);
}

// The orchestrator's hand-off is files, not agent notifications (a Haiku
// orchestrator waiting on "completion notifications" has ended its turn and
// never run finish). `wait` blocks until every investigator's output file
// exists, or the timeout, so the next step can always run straight after it.
function wait(stage) {
  if (stage !== 'investigate') {
    process.stderr.write('usage: wait investigate\n');
    process.exit(1);
  }
  if (!fs.existsSync(f('plan.json'))) return say('NOTHING_PENDING');
  const files = Object.values(readJson(f('plan.json')).repos).flatMap((r) => r.candidates).map((cf) => readJson(cf).outputFile);
  const deadline = Date.now() + Number(process.env.LOG_SWEEP_WAIT_SECONDS || 540) * 1000;
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
