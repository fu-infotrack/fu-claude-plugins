// Pure badge logic for the review-bot heartbeat Worker: liveness, Sydney-time
// formatting, and SVG rendering. No I/O and no clock — `now` is always passed
// in — so it runs unchanged under `node --test` and in the Workers runtime.

// A bot is live when its last ping is at most this old. Fixed, not learned:
// the loops tick about every 10 minutes, so 15 tolerates one late tick
// without flapping to "down".
export const STALE_MS = 15 * 60 * 1000;
export const TIME_ZONE = 'Australia/Sydney';

const COLORS = { up: '#2ea043', down: '#cf222e', none: '#8c959f' };

export function isLive(lastPing, now) {
  return Number.isFinite(lastPing) && now - lastPing <= STALE_MS;
}

const timeFmt = new Intl.DateTimeFormat('en-AU', {
  timeZone: TIME_ZONE, hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});
const dayFmt = new Intl.DateTimeFormat('en-AU', {
  timeZone: TIME_ZONE, year: 'numeric', month: 'numeric', day: 'numeric',
});

// Fixed names: ICU's short months differ by locale data ("Sep" vs "Sept").
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// The Sydney calendar day of `ms` as numbers, via parts — not a formatted
// string, whose layout is locale data too.
function sydneyDay(ms) {
  const p = Object.fromEntries(dayFmt.formatToParts(ms).map(({ type, value }) => [type, value]));
  return { year: Number(p.year), month: Number(p.month), day: Number(p.day) };
}

// "14:05" when `ms` falls on the same Sydney calendar day as `now`,
// otherwise "29 Sep 14:05".
export function formatTime(ms, now) {
  const time = timeFmt.format(ms);
  const d = sydneyDay(ms);
  const t = sydneyDay(now);
  if (d.year === t.year && d.month === t.month && d.day === t.day) return time;
  return `${d.day} ${MONTHS[d.month - 1]} ${time}`;
}

// One repo: up/down with the last ping time, or none if it never pinged.
export function repoBadge(lastPing, now) {
  if (!Number.isFinite(lastPing)) return { state: 'none', text: 'no bot' };
  return { state: isLive(lastPing, now) ? 'up' : 'down', text: formatTime(lastPing, now) };
}

// Every repo: the live ones only, one row each with its last ping, sorted by
// name. A dead bot drops off rather than showing red, so a retired repo needs
// no cleanup.
export function allBadge(rows, now) {
  const live = rows
    .filter((r) => isLive(r.last_ping, now))
    .sort((a, b) => a.repo.localeCompare(b.repo))
    .map((r) => ({ state: 'up', text: r.repo, detail: formatTime(r.last_ping, now) }));
  return live.length ? live : [{ state: 'none', text: 'no bot active' }];
}

function escapeXml(s) {
  return s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

const STATE_LABEL = { up: 'review bot up', down: 'review bot down', none: 'no review bot' };
const ROW_H = 20;
const TEXT_X = 38;
const textWidth = (s) => [...s].length * 7; // an estimate: ~7px/char at 11px

// Minimal badge, one row per entry: a coloured dot, a robot, the text, and an
// optional detail (the ping time) aligned in a second column. The dot is a
// <circle> rather than an emoji so the colour — the part that carries the
// meaning — never depends on the viewer's emoji font.
export function renderSvg(rows) {
  const textEnd = TEXT_X + Math.max(...rows.map((r) => textWidth(r.text)));
  const detailX = textEnd + 10;
  const detailW = Math.max(...rows.map((r) => (r.detail ? textWidth(r.detail) : 0)));
  const width = (detailW ? detailX + detailW : textEnd) + 8;
  const height = rows.length * ROW_H;
  const label = escapeXml(rows
    .map((r) => `${STATE_LABEL[r.state]}: ${r.text}${r.detail ? ` ${r.detail}` : ''}`)
    .join('; '));
  const body = rows.map((r, i) => {
    const y = i * ROW_H;
    return `<circle cx="10" cy="${y + 10}" r="5" fill="${COLORS[r.state]}"/>`
      + `<text x="19" y="${y + 14}">🤖</text>`
      + `<text x="${TEXT_X}" y="${y + 14}">${escapeXml(r.text)}</text>`
      + (r.detail ? `<text x="${detailX}" y="${y + 14}">${escapeXml(r.detail)}</text>` : '');
  }).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" role="img" aria-label="${label}">`
    + `<title>${label}</title>`
    + `<rect width="${width}" height="${height}" rx="3" fill="#444"/>`
    + `<g font-family="Verdana,DejaVu Sans,sans-serif" font-size="11" fill="#fff">${body}</g></svg>`;
}
