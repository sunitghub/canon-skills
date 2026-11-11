// t-ad6f: the one place the UI asks for the live sessions: the public read API (/api/v1/sessions), never a private route. An answer is
// `answered` only when the request succeeded and carries a `sessions` array; any other answer (a failed request, a non-JSON body, no array) gives
// no rows and `up` false, so a caller that must tell "none" from "could not ask" (the End menu) checks `answered`, and the rest read `rows`.
// `up` is X-Cockpit-Daemon: the daemon really answered (t-27bc), so an empty list means no sessions and not a failed poll.
// No imports: the board and the Cockpit shell both load this file.
export const SESSIONS_URL = '/api/v1/sessions';
// A board that does not answer within timeoutMs (the request or the body) gives the same empty answer as a failed one, so a caller never waits forever.
// Rows that are not objects are dropped: the callers read fields off every row.
export async function fetchSessions({ timeoutMs = 10000 } = {}) {
  const none = { answered: false, rows: [], up: false };
  const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(SESSIONS_URL, { signal: ctl.signal });
    if (!r.ok) return none;
    const body = await r.json();
    if (!body || !Array.isArray(body.sessions)) return none;
    const rows = body.sessions.filter(row => row && typeof row === 'object' && !Array.isArray(row));
    return { answered: true, rows, up: r.headers.get('X-Cockpit-Daemon') === 'up' };
  } catch { return none; } finally { clearTimeout(timer); }
}
