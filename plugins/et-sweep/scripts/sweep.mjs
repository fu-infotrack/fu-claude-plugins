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
  default:
    process.stderr.write(`unknown command: ${cmd}\n`);
    process.exit(1);
}
