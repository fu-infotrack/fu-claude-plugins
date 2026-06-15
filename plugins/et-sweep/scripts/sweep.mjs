#!/usr/bin/env node
// Thin CLI over sweep-lib. Converts ISO<->ms; prints JSON or strings to stdout.
// Usage:
//   node sweep.mjs window [lastTickMs|null]
//   node sweep.mjs filter-batch '<issuesJson>' <windowStartMs> <threshold>
//   node sweep.mjs classify '<matchesJson>'
//   node sweep.mjs title '<errorType>' '<message>'
//   node sweep.mjs marker '<issueId>'
import {
  windowStartMs, passesFilter, classify, buildTitle, buildMarker,
  parseRepoFromRemote, collectServices, buildServiceQuery, mergeConfig,
} from './sweep-lib.mjs';

const [, , cmd, ...args] = process.argv;

function out(v) {
  process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
  process.stdout.write('\n');
}

switch (cmd) {
  case 'window': {
    const lastTick = args[0] && args[0] !== 'null' ? Number(args[0]) : null;
    const now = Date.now();
    const startMs = windowStartMs(lastTick, now);
    out({ startMs, startIso: new Date(startMs).toISOString(), nowMs: now });
    break;
  }
  case 'filter-batch': {
    // issues: [{issueId, errorType, errorMessage, firstSeenIso, isRegression, totalCount, ...}]
    const issues = JSON.parse(args[0]);
    const windowStart = Number(args[1]);
    const threshold = Number(args[2]);
    const passers = issues.filter((i) =>
      passesFilter(
        { firstSeenMs: Date.parse(i.firstSeenIso), isRegression: !!i.isRegression, totalCount: Number(i.totalCount) },
        windowStart,
        threshold,
      ));
    out(passers);
    break;
  }
  case 'classify': {
    out(classify(JSON.parse(args[0])));
    break;
  }
  case 'title': {
    out(buildTitle(args[0], args[1]));
    break;
  }
  case 'marker': {
    out(buildMarker(args[0]));
    break;
  }
  case 'resolve': {
    // Resolve et-sweep config: user < auto-detect < project < cli. Prints JSON.
    const { execFileSync } = await import('node:child_process');
    const fs = await import('node:fs');
    const path = await import('node:path');
    const os = await import('node:os');
    const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
    const userCfg = readJson(path.join(os.homedir(), '.claude', 'fu-tools', 'config.json'));
    let projCfg = null;
    for (let dir = process.cwd(); ; dir = path.dirname(dir)) {
      const cand = path.join(dir, '.claude', '.fu-tools.json');
      if (fs.existsSync(cand)) { projCfg = readJson(cand); break; }
      if (dir === path.dirname(dir)) break;
    }
    let repo = null;
    try { repo = parseRepoFromRemote(execFileSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8' }).trim()); } catch { /* no remote */ }
    const appNames = [];
    for (const f of fs.readdirSync(process.cwd())) {
      if (/^k8_settings.*\.json$/.test(f)) {
        const j = readJson(path.join(process.cwd(), f));
        for (const m of JSON.stringify(j || {}).matchAll(/"app_name"\s*:\s*"([^"]+)"/g)) appNames.push(m[1]);
      }
    }
    const auto = {};
    if (repo) auto.repo = repo;
    const services = collectServices(appNames);
    if (services.length) auto.services = services;
    const cli = args[0] ? JSON.parse(args[0]) : {};
    const merged = mergeConfig(userCfg, projCfg, auto, cli, 'et-sweep');
    if (!merged.env) merged.env = 'prod';
    if (merged.services && merged.services.length) merged.query = buildServiceQuery(merged.services, merged.env);
    out(merged);
    break;
  }
  default:
    process.stderr.write(`unknown command: ${cmd}\n`);
    process.exit(1);
}
