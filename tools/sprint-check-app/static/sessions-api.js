// t-ad6f: the one place the UI asks for the live sessions: the public read API (/api/v1/sessions), never a private route. An answer is
// `answered` only when the request succeeded and carries a `sessions` array; any other answer (a failed request, a non-JSON body, no array) gives
// no rows and `up` false, so a caller that must tell "none" from "could not ask" (the End menu) checks `answered`, and the rest read `rows`.
// `up` is X-Cockpit-Daemon: the daemon really answered (t-27bc), so an empty list means no sessions and not a failed poll.
// No imports: the board and the Cockpit shell both load this file.
export const SESSIONS_URL = '/api/v1/sessions';
export async function fetchSessions() {
  try {
    const r = await fetch(SESSIONS_URL);
    if (!r.ok) return { answered: false, rows: [], up: false };
    const body = await r.json();
    if (!body || !Array.isArray(body.sessions)) return { answered: false, rows: [], up: false };
    return { answered: true, rows: body.sessions, up: r.headers.get('X-Cockpit-Daemon') === 'up' };
  } catch { return { answered: false, rows: [], up: false }; }
}
