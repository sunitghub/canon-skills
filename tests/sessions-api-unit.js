#!/usr/bin/env node
// sessions-api-unit — t-ad6f. Protects static/sessions-api.js, the one place the board and the Cockpit shell ask for the live sessions
// (every session poll, the close-tab guard, the Agents list, Admin, the End menu): it calls the public /api/v1/sessions, unwraps `sessions`,
// reads the daemon-up flag from X-Cockpit-Daemon, and gives answered:false, no rows and up:false for a failed request, a not-ok status, a body that
// is not JSON and a body with no `sessions` array. The End menu relies on answered:false to say "could not check" rather than "no sessions".
// Usage: node tests/sessions-api-unit.js
const assert = require('assert');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  const { fetchSessions, SESSIONS_URL } = await import(pathToFileURL(path.join(__dirname, '..', 'tools', 'sprint-check-app', 'static', 'sessions-api.js')).href);
  const reply = (status, body, daemon) => async url => {
    reply.url = url;
    return { ok: status >= 200 && status < 300, status, headers: { get: h => (h === 'X-Cockpit-Daemon' ? daemon : null) }, json: async () => { if (body === undefined) throw new SyntaxError('not json'); return body; } };
  };
  const none = { answered: false, rows: [], up: false };

  global.fetch = reply(200, { schema: 'v1', sessions: [{ ticket: 't-aaaa' }] }, 'up');
  assert.deepStrictEqual(await fetchSessions(), { answered: true, rows: [{ ticket: 't-aaaa' }], up: true });
  assert.strictEqual(reply.url, '/api/v1/sessions');
  assert.strictEqual(SESSIONS_URL, '/api/v1/sessions');

  global.fetch = reply(200, { schema: 'v1', sessions: [] }, 'down');   // a down daemon: an empty list that is NOT "no sessions"
  assert.deepStrictEqual(await fetchSessions(), { answered: true, rows: [], up: false });
  global.fetch = reply(200, { sessions: [] }, null);                    // no header at all: not up
  assert.deepStrictEqual(await fetchSessions(), { answered: true, rows: [], up: false });

  global.fetch = reply(503, { error: 'x' }, 'up');                      // not ok, even with the header
  assert.deepStrictEqual(await fetchSessions(), none);
  global.fetch = reply(200, undefined, 'up');                           // not JSON
  assert.deepStrictEqual(await fetchSessions(), none);
  for (const body of [null, 'x', 5, [], {}, { sessions: null }, { sessions: {} }]) {   // no `sessions` array (the old bare array is not one)
    global.fetch = reply(200, body, 'up');
    assert.deepStrictEqual(await fetchSessions(), none, JSON.stringify(body));
  }
  global.fetch = async () => { throw new TypeError('network'); };       // the request itself fails
  assert.deepStrictEqual(await fetchSessions(), none);

  console.log('sessions-api-unit: ok (url, unwrap, daemon flag, 10 failure shapes)');
})().catch(e => { console.error('FAIL: sessions-api-unit:', e.message); process.exit(1); });
