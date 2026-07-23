#!/usr/bin/env node
// Thin CLI over log-sweep-lib. Converts ISO<->ms; prints JSON or strings to stdout.
// Usage:
//   node sweep.mjs window [lastTickMs|null]
//   node sweep.mjs classify '<matchesJson>'
//   node sweep.mjs title '<errorType>' '<message>'
//   node sweep.mjs marker '<sig>'
//   node sweep.mjs signature '<json:{errorKind,service,stack,message,appNamespace}>'
//   node sweep.mjs resolve '<cliJson>'
import {
  windowStartMs, classify, buildTitle, buildMarker, buildSignature,
  parseRepoFromRemote, collectServices, buildLogQuery, mergeConfig,
} from './log-sweep-lib.mjs';

const [, , cmd, ...args] = process.argv;

function out(v) {
  process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
  process.stdout.write('\n');
}

function asArray(v) {
  if (Array.isArray(v)) return v.filter(Boolean);
  return v ? [v] : [];
}

switch (cmd) {
  case 'window': {
    const lastTick = args[0] && args[0] !== 'null' ? Number(args[0]) : null;
    const now = Date.now();
    const startMs = windowStartMs(lastTick, now);
    out({ startMs, startIso: new Date(startMs).toISOString(), nowMs: now });
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
  case 'signature': {
    const i = JSON.parse(args[0]);
    out(buildSignature(i.errorKind, i.service, i.stack, i.message, asArray(i.appNamespace)));
    break;
  }
  case 'resolve': {
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
    const merged = mergeConfig(userCfg, projCfg, auto, cli, 'log-sweep');
    if (!merged.env) merged.env = 'prod';
    if (!merged.statusQuery) merged.statusQuery = merged.status_query || 'status:error';
    merged.appNamespace = asArray(merged.appNamespace || merged.app_namespace);
    merged.logsUrlBase = merged.logsUrlBase || merged.logs_url_base || null;
    if (merged.services && merged.services.length) {
      merged.query = buildLogQuery(merged.services, merged.env, merged.statusQuery);
    }
    out(merged);
    break;
  }
  default:
    process.stderr.write(`unknown command: ${cmd}\n`);
    process.exit(1);
}
