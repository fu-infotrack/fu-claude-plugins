#!/usr/bin/env node
// The cloud routine's deterministic side. A routine installs no plugin and has
// no pup — Datadog is reachable only through the Datadog MCP connector, which
// only a model can call. So the model does the two Datadog/judgement steps in
// sub-agents (collector, investigator) and this script does everything else:
// config, the GitHub issue index, signatures, dedup, the release gate, and
// filing. GitHub is REST only (`gh api`, explicit pages): cloud sessions answer
// GraphQL with 403, and their proxy rejects `--paginate`'s follow-up links.
//
// Every step prints a status token first; the orchestrator never reads data.
//   node routine.mjs prepare [--live|--observe] ['<config-json>']   (cwd = the target repo's clone)
//   node routine.mjs plan
//   node routine.mjs finish
// The handoff between steps is on disk, in $HOME/.claude/log-sweep/routine/.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  windowStartMs, classify, buildTitle, buildSignature, releaseCheck,
  parseCollectorOutput, pruneBuckets, issueMatchesBySig, buildBucketQuery,
  validateInvestigation, composeIssueBody,
} from './log-sweep-lib.mjs';

const SCRIPTS = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.dirname(SCRIPTS);
const DIR = path.join(os.homedir(), '.claude', 'log-sweep', 'routine');
const BUCKET_CAP = 20;
const SURVIVOR_CAP = 10;
const MAX_PAGES = 30;

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

function block(header, lines) {
  say(`--- ${header} ---`);
  for (const l of lines) say(l);
}

function prepare(args) {
  const mode = args.includes('--live') ? 'live' : 'observe';
  const cfgArg = args.find((a) => !a.startsWith('--')) || '{}';
  fs.rmSync(DIR, { recursive: true, force: true });
  fs.mkdirSync(DIR, { recursive: true });
  if (!onPath('gh')) return say('SKIP — gh is not on PATH');

  let cfg;
  try {
    cfg = JSON.parse(execFileSync(process.execPath, [path.join(SCRIPTS, 'sweep.mjs'), 'resolve', cfgArg], { encoding: 'utf8' }));
  } catch (e) { return say(`SKIP — config did not resolve: ${firstLine(e)}`); }
  if (!cfg.repo) return say('SKIP — no target repo (no GitHub remote in the cwd and no "repo" in the config)');
  if (!cfg.query) return say(`SKIP — no services for ${cfg.repo} (no k8_settings app_name in the cwd and no "services" in the config)`);

  const nowMs = Date.now();
  const startMs = windowStartMs(null, nowMs);
  const notes = [];

  let issues;
  try { issues = ghPages(`repos/${cfg.repo}/issues?state=all&labels=datadog-logs`); } catch (e) {
    return say(`SKIP — could not list ${cfg.repo}'s datadog-logs issues, so nothing can be deduped: ${firstLine(e)}`);
  }
  let releases = [];
  try {
    releases = JSON.parse(gh([`repos/${cfg.repo}/releases?per_page=30`])).map((r) => ({ tag: r.tag_name, publishedAt: r.published_at }));
  } catch (e) { notes.push(`release gate off (releases unreadable: ${firstLine(e)}) — regressions reopen`); }

  writeJson(f('run.json'), {
    mode, repo: cfg.repo, env: cfg.env, query: cfg.query, statusQuery: cfg.statusQuery,
    errorFacet: cfg.errorFacet, appNamespace: cfg.appNamespace, logsUrlBase: cfg.logsUrlBase,
    threshold: Number(cfg.count ?? cfg.count_threshold ?? cfg.countThreshold ?? 1),
    startIso: new Date(startMs).toISOString(), nowIso: new Date(nowMs).toISOString(),
    sourceDir: process.cwd(), matches: issueMatchesBySig(issues), releases, notes,
  });

  say(`PROCEED collector ${mode} ${cfg.repo}`);
  block('collector', [
    `Read ${path.join(PLUGIN, 'routine-collector.md')} and follow it exactly. Your inputs:`,
    '',
    `QUERY=${cfg.query}`,
    `ERROR_FACET=${cfg.errorFacet}`,
    `STACK_FIELD=${String(cfg.stackPath).split('.').pop()}`,
    `FROM=${new Date(startMs).toISOString()}`,
    `TO=${new Date(nowMs).toISOString()}`,
    `THRESHOLD=${Number(cfg.count ?? cfg.count_threshold ?? cfg.countThreshold ?? 1)}`,
    `CAP=${BUCKET_CAP}`,
    `OUTPUT_FILE=${f('buckets.json')}`,
  ]);
}

function plan() {
  if (!fs.existsSync(f('run.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  let parsed;
  try { parsed = parseCollectorOutput(readJson(f('buckets.json'))); } catch (e) { parsed = { ok: false, error: firstLine(e) }; }
  if (!parsed.ok) return say(`FAILED — the collector's buckets file is unusable (${parsed.error}); nothing filed`);

  const notes = [...run.notes];
  const { kept, belowThreshold, overCap } = pruneBuckets(parsed.buckets, run.threshold, BUCKET_CAP);
  if (overCap) notes.push(`dropped ${overCap} buckets over the ${BUCKET_CAP}-bucket cap`);
  let alreadyOpen = 0;
  const survivors = [];
  for (const b of kept) {
    const sample = b.samples[0] || {};
    const { sig, frame, confidence } = buildSignature(b.errorKind, b.service, sample.stack, sample.message, run.appNamespace);
    const matches = run.matches[sig] || [];
    const cls = classify(matches);
    if (cls.kind === 'ALREADY_OPEN') { alreadyOpen++; continue; }
    let release = null;
    if (cls.kind === 'REGRESSION') {
      const closedAt = matches.find((m) => m.number === cls.number)?.closedAt;
      release = releaseCheck(b.versions, run.releases, Date.parse(closedAt));
      if (!release.regressed) {
        notes.push(`held ${sig} #${cls.number}: fix not in prod yet (still on ${release.preFixVersions.join(', ')})`);
        continue;
      }
    }
    survivors.push({ b, sample, sig, frame, confidence, cls, release });
  }
  survivors.sort((x, y) => y.b.count - x.b.count);
  if (survivors.length > SURVIVOR_CAP) notes.push(`dropped ${survivors.length - SURVIVOR_CAP} candidates over the ${SURVIVOR_CAP}-per-run cap`);
  const picked = survivors.slice(0, SURVIVOR_CAP);

  const candidates = picked.map(({ b, sample, sig, frame, confidence, cls, release }) => {
    const bucketQuery = buildBucketQuery(b.service, run.env, run.statusQuery, run.errorFacet, b.errorKind);
    const errorMessage = (sample.message || '').split('\n')[0];
    const cand = {
      sig, repo: run.repo, mode: run.mode, classification: cls.kind, number: cls.number ?? null,
      errorKind: b.errorKind, service: b.service, env: run.env, count: b.count, frame, confidence,
      errorMessage, lastSeenIso: sample.timestamp || null, windowStartIso: run.startIso,
      title: buildTitle(b.errorKind, frame || errorMessage), bucketQuery,
      logsUrl: run.logsUrlBase ? `${run.logsUrlBase}${encodeURIComponent(bucketQuery)}` : null,
      postFixCount: release?.postFixCount ?? null, versions: b.versions,
      candidateFile: f(`cand-${sig}.json`), sampleFile: f(`sample-${sig}.json`), outputFile: f(`inv-${sig}.json`),
    };
    writeJson(cand.candidateFile, cand);
    writeJson(cand.sampleFile, b.samples);
    return cand;
  });
  writeJson(f('plan.json'), { candidates: candidates.map((c) => c.candidateFile), notes });

  const summary = `buckets=${parsed.buckets.length} below-threshold=${belowThreshold} already-open=${alreadyOpen} candidates=${candidates.length}`;
  if (!candidates.length) {
    say(`NO_WORK — ${summary}`);
    for (const n of notes) say(`  ${n}`);
    return;
  }
  say(`PROCEED ${candidates.length} — ${summary}`);
  for (const c of candidates) {
    block(`investigator ${c.sig}`, [
      `Read ${path.join(PLUGIN, 'routine-investigator.md')} and follow it exactly. Your inputs:`,
      '',
      `CANDIDATE_FILE=${c.candidateFile}`,
      `SAMPLE_FILE=${c.sampleFile}`,
      `OUTPUT_FILE=${c.outputFile}`,
      `SOURCE_DIR=${run.sourceDir}`,
    ]);
  }
}

function fileOne(c, v) {
  const repo = c.repo;
  if (c.classification === 'NEW') {
    const issue = JSON.parse(gh([`repos/${repo}/issues`, '--method', 'POST', '--input', '-'], JSON.stringify({
      title: c.title, body: composeIssueBody(c.sig, v.body), labels: ['datadog-logs', 'auto-filed', `sev:${v.severity}`],
    })));
    return `#${issue.number} created (${v.severity}) — ${c.title}`;
  }
  gh([`repos/${repo}/issues/${c.number}`, '--method', 'PATCH', '-f', 'state=open']);
  gh([`repos/${repo}/issues/${c.number}/comments`, '--method', 'POST', '--input', '-'], JSON.stringify({ body: v.comment }));
  return `#${c.number} reopened (${v.severity}) — ${c.title}`;
}

function finish() {
  if (!fs.existsSync(f('plan.json'))) return say('NOTHING_PENDING');
  const run = readJson(f('run.json'));
  const { candidates, notes } = readJson(f('plan.json'));
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
  const verb = run.mode === 'live' ? 'filed' : 'would-file';
  say(`${run.mode === 'live' ? 'SWEPT' : 'OBSERVED'} ${run.repo} — ${verb}=${n.filed} dropped=${n.dropped} failed=${n.failed}`);
  for (const l of [...lines, ...notes]) say(`  ${l}`);
  fs.rmSync(f('plan.json'));
}

const [, , cmd, ...args] = process.argv;
const commands = { prepare: () => prepare(args), plan, finish };
if (!commands[cmd]) {
  process.stderr.write(`unknown command: ${cmd}\n`);
  process.exit(1);
}
commands[cmd]();
