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

// Every repo: the live ones only, by name. A dead bot drops off rather than
// showing red, so a retired repo needs no cleanup.
export function allBadge(rows, now) {
  const live = rows
    .filter((r) => isLive(r.last_ping, now))
    .map((r) => r.repo)
    .sort((a, b) => a.localeCompare(b));
  if (live.length === 0) return { state: 'none', text: 'no bot active' };
  return { state: 'up', text: live.join(' · ') };
}

function escapeXml(s) {
  return s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

// Minimal badge: a coloured dot, a robot, the text. The dot is a <circle>
// rather than an emoji so the colour — the part that carries the meaning —
// never depends on the viewer's emoji font. Width is an estimate (~7px/char).
export function renderSvg({ state, text }) {
  const textX = 38;
  const width = textX + [...text].length * 7 + 8;
  const label = escapeXml(`${state === 'up' ? 'review bot up' : state === 'down' ? 'review bot down' : 'no review bot'}: ${text}`);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="20" role="img" aria-label="${label}">`
    + `<title>${label}</title>`
    + `<rect width="${width}" height="20" rx="3" fill="#444"/>`
    + `<circle cx="10" cy="10" r="5" fill="${COLORS[state]}"/>`
    + `<g font-family="Verdana,DejaVu Sans,sans-serif" font-size="11" fill="#fff">`
    + `<text x="19" y="14">🤖</text>`
    + `<text x="${textX}" y="14">${escapeXml(text)}</text>`
    + `</g></svg>`;
}
