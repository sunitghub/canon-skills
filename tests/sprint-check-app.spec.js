// @ts-check
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const { execFileSync, spawn } = require('child_process');
const net = require('net');

const BASE = process.env.SPRINT_CHECK_BASE || 'http://localhost:8423';
const PROJECT_ROOT = process.env.SPRINT_CHECK_TEST_ROOT || process.cwd();

// 1x1 transparent PNG, real decodable bytes (t-626d paste tests).
const PASTE_PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

// Simulates an OS clipboard image paste — real clipboard access is unreliable
// in headless Chromium, so this dispatches a synthetic ClipboardEvent with a
// constructed DataTransfer/File, which the app's paste listeners can't tell
// apart from a real paste (both read clipboardData.items).
async function pasteImageIntoElement(page, selector, { base64 = PASTE_PNG_B64, filename = 'clipboard.png', mime = 'image/png' } = {}) {
  await page.evaluate(async ({ selector, base64, filename, mime }) => {
    const el = document.querySelector(selector);
    el.focus();
    const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
    const file = new File([bytes], filename, { type: mime });
    const dt = new DataTransfer();
    dt.items.add(file);
    el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
  }, { selector, base64, filename, mime });
}

test.describe('board modal', () => {
  test('feature tour copy reflects current sprint gates', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    await page.locator('#tour-btn').click();

    const tour = page.locator('#tour-panel');
    await expect(tour).toBeVisible();
    await expect(tour).toContainText('no hosted server');
    await expect(tour).not.toContainText('no server · no account');
    await expect(tour).toContainText('no unchecked boxes including ## QA');
    await expect(tour).toContainText('Plan ## Sign-off is checked');
    await expect(tour).toContainText('board-created Acceptance and Plan');
    await expect(tour).toContainText('research.md');
    await expect(tour).toContainText('eval-report.md');
    await expect(tour).toContainText('summary.md');
    await expect(tour).toContainText('## Wrapup Gates');
  });

  test('header shows the semantic version; the "?" panel lists all component versions at the top (t-99fa/t-5c20)', async ({ page }) => {
    await page.route('**/api/version', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ version: '0.1.0', commit: 'abc1234', daemon: '0.1.0 (def5678)' }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    // Header shows the human semantic version — not a bare git hash.
    await expect(page.locator('#h-version')).toHaveText('canon v0.1.0');
    // Versions block is the FIRST section in the "?" tour panel body and lists
    // every component (canon semver + board build + cockpit-daemon build).
    await expect(page.locator('.tour-body > .tour-section-title').first()).toHaveText('Versions');
    await expect(page.locator('#tv-canon')).toHaveText('v0.1.0 (abc1234)');
    await expect(page.locator('#tv-board')).toHaveText('abc1234');
    await expect(page.locator('#tv-daemon')).toHaveText('0.1.0 (def5678)');
    // The "?" button opens the panel.
    await page.locator('#tour-btn').click();
    await expect(page.locator('#tour-overlay')).toHaveClass(/open/);
    await expect(page.locator('#tour-versions')).toBeVisible();
  });

  test('sidebar shows total commit count badge next to Recent Commits', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const badge = page.locator('#s-commits-total');
    await expect(badge).toBeVisible();
    const text = await badge.textContent();
    expect(Number(text)).toBeGreaterThan(0);
  });

  test('Description tab appears on tickets with docs', async ({ page }) => {
    // Uses its own fixture ticket rather than "the first/newest card" —
    // that assumption broke once a later-created ticket in this same repo
    // happened to have no docs (see doc-less coverage in the test below).
    const id = `t-desc-tab-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Description tab test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Approach',
        'Has docs, so the Description tab should appear.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.waitForSelector('#m-docs', { timeout: 5000 });
      const withDocsTabs = await page.locator('#m-docs .doc-tab').allTextContents();
      expect(withDocsTabs.map(t => t.trim())).toContain('Description');
      await page.keyboard.press('Escape');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('clicking an in-progress card opens the ticket modal', async ({ page }) => {
    const id = `t-click-${Date.now()}`;
    const title = `Click open ${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');

      const card = page.locator(`.col-progress .card[data-id="${id}"]`);
      await expect(card).toBeVisible();
      await card.click();
      await expect(page.locator('#m-id')).toHaveText(id);
      await expect(page.locator('#m-title')).toHaveText(title);
      await expect.poll(() => page.evaluate(() => window.__sprintCheckOpenModalCount || 0)).toBe(1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('double-clicking a card Copy button copies the .tickets/<id> folder path (single-click still copies the id)', async ({ page }) => {
    const id = `t-copy-${Date.now()}`;
    const title = `Copy folder ${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));

      // Stub the clipboard before app scripts run — real clipboard is unreliable headless.
      await page.addInitScript(() => {
        window.__copied = [];
        navigator.clipboard.writeText = (t) => { window.__copied.push(t); return Promise.resolve(); };
      });

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');

      const copyBtn = page.locator(`.col-progress .card[data-id="${id}"] .card-id-copy`);
      await expect(copyBtn).toBeVisible();

      await copyBtn.click();
      await expect.poll(() => page.evaluate(() => window.__copied.at(-1))).toBe(id);

      await copyBtn.dblclick();
      await expect.poll(() => page.evaluate(() => window.__copied.at(-1))).toMatch(new RegExp(`/\\.tickets/${id}$`));
      // The double-click must not have left the modal open.
      await expect(page.locator('#m-id')).not.toHaveText(id);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a signed-off ticket shows the ready dot and label, no flag', async ({ page }) => {
    const id = `t-ready-pop-${Date.now()}`;
    const title = `Ready popover ${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), [
        '# Acceptance',
        '',
        '## Criteria',
        '- [x] Ready',
        '',
        '## Test Plan',
        '- [x] Tested',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Approach',
        'Use the existing board readiness indicator.',
        '',
        '## Sign-off',
        '- [x] Plan approved',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id);
      const indicator = page.locator(`.card[data-id="${id}"] .ready-indicator`);
      await expect(indicator).toBeVisible();
      await expect(indicator).toHaveClass(/ready/);
      await expect(indicator.locator('.ready-dot')).toBeVisible();
      await expect(indicator).toContainText('ready');
      await expect(indicator.locator('.ready-flag')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('plan approach without sign-off is not ready', async ({ page }) => {
    const id = `t-needs-signoff-${Date.now()}`;
    const title = `Needs signoff ${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), [
        '# Acceptance',
        '',
        '## Criteria',
        '- [x] Ready',
        '',
        '## Test Plan',
        '- [x] Tested',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        '- [ ] Plan approved',
        '',
        '## Approach',
        'Use the existing board readiness indicator.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id);
      const indicator = page.locator(`.card[data-id="${id}"] .ready-indicator`);
      await expect(indicator).toHaveClass(/incomplete|not-ready/);
      const flag = indicator.locator('.ready-flag');
      await expect(flag).toBeVisible();
      await expect(flag).toHaveAttribute('aria-label', /needs signoff/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('unchecked QA box blocks ready even with filled Criteria and Test Plan', async ({ page }) => {
    const id = `t-unchecked-qa-${Date.now()}`;
    const title = `Unchecked QA ${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-07-02T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), [
        '# Acceptance',
        '',
        '## Criteria',
        '- [x] Ready',
        '',
        '## Test Plan',
        '- [x] Tested',
        '',
        '## QA',
        '- [ ] Tested locally',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Use the existing board readiness indicator.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id);
      const indicator = page.locator(`.card[data-id="${id}"] .ready-indicator`);
      await expect(indicator).toHaveClass(/incomplete|not-ready/);
      const flag = indicator.locator('.ready-flag');
      await expect(flag).toBeVisible();
      await expect(flag).toHaveAttribute('aria-label', /unchecked items/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('editing docs works for quoted numeric ticket ids', async ({ page }) => {
    const id = '001';
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.rmSync(ticketDir, { recursive: true, force: true });
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: "${id}"`,
        'status: in_progress',
        'type: feature',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Quoted numeric ID',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), [
        '# Acceptance',
        '',
        '## Criteria',
        '- [ ] Existing criterion',
        '',
        '## Test Plan',
        '- [ ] Existing test',
        '',
        '## QA',
        '- [ ] Existing QA',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
      await expect(page.locator('#m-title')).toHaveText('Quoted numeric ID');
      await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Acceptance');
      await expect(page.locator('#btn-edit-doc')).toBeVisible();
      await page.locator('#btn-edit-doc').click();
      await expect(page.locator('#m-edit-area')).toBeVisible();
      await expect(page.locator('#m-edit-area')).toHaveValue(/Existing criterion/);
      await page.locator('#m-edit-area').fill([
        '# Acceptance',
        '',
        '## Criteria',
        '- [ ] Updated criterion',
        '',
        '## Test Plan',
        '- [ ] Existing test',
        '',
        '## QA',
        '- [ ] Existing QA',
        '',
      ].join('\n'));

      page.on('dialog', dialog => {
        throw new Error(`unexpected dialog: ${dialog.message()}`);
      });
      await page.locator('#btn-save-top').click();
      await expect(page.locator('#m-edit-area')).toBeHidden();
      await expect(page.locator('#m-body')).toContainText('Updated criterion');
      expect(fs.readFileSync(path.join(ticketDir, 'acceptance.md'), 'utf8')).toContain(`Ticket: \`${id}\``);
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('first doc tab is active on open (ticket with docs)', async ({ page }) => {
    const title = `Doc tab active test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      // Write acceptance.md so the ticket has at least one doc
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', createdId);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), `# Acceptance\nTicket: \`${createdId}\`\n## Criteria\n- [ ] Done\n`);

      await page.reload();
      await page.waitForLoadState('networkidle');

      await page.locator('.card', { hasText: title }).click();
      await page.waitForSelector('#m-docs .doc-tab.active', { timeout: 5000 });

      const activeTab = page.locator('#m-docs .doc-tab.active').first();
      await expect(activeTab).toBeVisible();
      await expect(page.locator('#m-body')).not.toBeEmpty();
    } finally {
      if (createdId) {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
      }
    }
  });

  test('status badges use light text on saturated fills in light mode via --badge-fg (t-2d8e)', async ({ page }) => {
    await page.route('**/api/cockpit-sessions', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify([{ session: 's1', ticket: 't-2lv7', project_root: '/Users/me/p', cwd: '/Users/me/p', agent: 'claude', status: 'running', started: '2026-09-10T00:00:00Z' }]),
    }));
    await page.route('**/api/cockpit', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:1', stale: false }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    const badge = page.locator('.cockpit-session-row .cs-status.running').first();
    await expect(badge).toBeVisible();
    // Dark theme (default :root): dark ink on the light-blue fill.
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
    await expect(badge).toHaveCSS('color', 'rgb(11, 15, 20)');
    // Light theme: white on the saturated blue fill (shared --badge-fg).
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
    await expect(badge).toHaveCSS('color', 'rgb(255, 255, 255)');
  });

  test('Main checkout sends this board\u2019s project root as the cockpit cwd (t-fc91)', async ({ page }) => {
    await page.route('**/api/cockpit', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:59999' }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    // Main checkout (cwd '') must carry THIS board's project root — not be omitted
    // (else a shared daemon resolves it to its launch project → wrong project).
    // t-8a2a: mountCockpitTerminal now acts on the ACTIVE tab's own iframe —
    // stand one up directly (same as openCockpit's "new tab" branch would)
    // before calling it, since this test drives the function in isolation.
    const mainSrc = await page.evaluate(async () => {
      state.gitRoot = '/Users/me/canon';
      const iframe = document.createElement('iframe');
      document.getElementById('ck-term').appendChild(iframe);
      cockpitTabs['t-ab12'] = newCockpitTabState('t-ab12', iframe);
      setActiveTab('t-ab12');
      await mountCockpitTerminal({ id: 't-ab12' }, '');
      return document.getElementById('ck-iframe').src;
    });
    expect(mainSrc).toContain('ticket=t-ab12');
    expect(mainSrc).toContain('cwd=' + encodeURIComponent('/Users/me/canon'));

    // A selected worktree still sends its own path unchanged.
    const wtSrc = await page.evaluate(async () => {
      state.gitRoot = '/Users/me/canon';
      await mountCockpitTerminal({ id: 't-ab12' }, '/Users/me/wt/sprint-x');
      return document.getElementById('ck-iframe').src;
    });
    expect(wtSrc).toContain('cwd=' + encodeURIComponent('/Users/me/wt/sprint-x'));
  });

  test('a stale/empty state.gitRoot triggers a fresh /api/git verification before Main checkout mounts (t-0a73)', async ({ page }) => {
    await page.route('**/api/cockpit', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:59999' }),
    }));
    await page.route('**/api/git', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ branch: 'main', project: 'todo', root: '/Users/agentops/ToDo', modified: 0, log: [] }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    // t-0a73: state.gitRoot empty here simulates loadData()'s catch branch
    // substituting MOCK.git (no `root` field) after a transient fetch failure
    // — the exact live-reproduced cause. Must NOT send an empty cwd; must
    // fetch a fresh, real root and use it instead.
    const src = await page.evaluate(async () => {
      state.gitRoot = '';
      const iframe = document.createElement('iframe');
      document.getElementById('ck-term').appendChild(iframe);
      cockpitTabs['t-ab12'] = newCockpitTabState('t-ab12', iframe);
      setActiveTab('t-ab12');
      await mountCockpitTerminal({ id: 't-ab12' }, '');
      return document.getElementById('ck-iframe').src;
    });
    expect(src).toContain('cwd=' + encodeURIComponent('/Users/agentops/ToDo'));
  });

  test('Main checkout refuses to mount (fail-safe) when no real project root can be verified (t-0a73)', async ({ page }) => {
    await page.route('**/api/cockpit', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:59999' }),
    }));
    await page.route('**/api/git', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ branch: 'main', project: 'todo', modified: 0, log: [] }), // no `root`
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const result = await page.evaluate(async () => {
      state.gitRoot = '';
      const iframe = document.createElement('iframe');
      document.getElementById('ck-term').appendChild(iframe);
      cockpitTabs['t-ab12'] = newCockpitTabState('t-ab12', iframe);
      setActiveTab('t-ab12');
      const before = document.getElementById('ck-iframe').src;
      await mountCockpitTerminal({ id: 't-ab12' }, '');
      return { src: document.getElementById('ck-iframe').src, before, msg: document.getElementById('ck-term-msg').textContent };
    });
    // The iframe must never be pointed at a doomed empty-cwd session — src
    // stays unchanged from its pre-call value, and the fail-safe message
    // explains why instead of silently misrouting to the daemon's default.
    expect(result.src).toBe(result.before);
    expect(result.msg).toContain("Could not verify this project's root");
  });

  test('a Windows-native git.root is normalized to forward slashes when state.gitRoot is set (t-1da3)', async ({ page }) => {
    await page.route('**/api/cockpit', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:59999' }),
    }));
    // t-1da3: server.py's load_git() returns str(Path) -- native OS separators,
    // backslashes on Windows -- unlike worktree cwd values (git worktree list
    // --porcelain's own forward-slashed output). The daemon's cwdPrefillRe
    // (t-7590) deliberately assumes every cwd it receives is already
    // forward-slashed; a raw Windows path here previously reset it to "".
    // Routed BEFORE goto so the page's own initial loadData() call (which sets
    // state.gitRoot via renderHeader()) exercises the real assignment path,
    // not a test-only shortcut.
    await page.route('**/api/git', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ branch: 'main', project: 'ToDo', root: 'C:\\Users\\agentops\\Documents\\ToDo', modified: 0, log: [] }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const result = await page.evaluate(async () => {
      const gitRootAfterLoad = state.gitRoot;
      const iframe = document.createElement('iframe');
      document.getElementById('ck-term').appendChild(iframe);
      cockpitTabs['t-ab12'] = newCockpitTabState('t-ab12', iframe);
      setActiveTab('t-ab12');
      await mountCockpitTerminal({ id: 't-ab12' }, '');
      return { gitRootAfterLoad, src: document.getElementById('ck-iframe').src };
    });
    expect(result.gitRootAfterLoad).toBe('C:/Users/agentops/Documents/ToDo');
    expect(result.src).toContain('cwd=' + encodeURIComponent('C:/Users/agentops/Documents/ToDo'));
    expect(result.src).not.toContain(encodeURIComponent('\\'));
  });

  test('a POSIX git.root is unaffected by the forward-slash normalization (t-1da3)', async ({ page }) => {
    await page.route('**/api/cockpit', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:59999' }),
    }));
    await page.route('**/api/git', r => r.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ branch: 'main', project: 'canon', root: '/Users/me/canon', modified: 0, log: [] }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const result = await page.evaluate(async () => {
      const gitRootAfterLoad = state.gitRoot;
      const iframe = document.createElement('iframe');
      document.getElementById('ck-term').appendChild(iframe);
      cockpitTabs['t-ab12'] = newCockpitTabState('t-ab12', iframe);
      setActiveTab('t-ab12');
      await mountCockpitTerminal({ id: 't-ab12' }, '');
      return { gitRootAfterLoad, src: document.getElementById('ck-iframe').src };
    });
    expect(result.gitRootAfterLoad).toBe('/Users/me/canon');
    expect(result.src).toContain('cwd=' + encodeURIComponent('/Users/me/canon'));
  });

  test('"No description." placeholder is gone', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const firstCard = page.locator('.card').first();
    await firstCard.click();
    await page.waitForSelector('#m-body', { timeout: 5000 });

    await expect(page.locator('#m-body')).not.toContainText('No description.');
  });

  test('doc-less tickets render ticket body in read-only modal', async ({ page }) => {
    const title = `Doc-less modal body check ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-body').fill('## Context\nTicket body should render without sprint docs.\n\n## Notes\n- Uses existing markdown renderer');
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      await card.click();

      await expect(page.locator('#m-docs .doc-tab')).toHaveCount(0);
      await expect(page.locator('#m-body')).toContainText('Ticket body should render without sprint docs.');
      await expect(page.locator('#m-body')).toContainText('Uses existing markdown renderer');
      await expect(page.locator('.section-jump-link', { hasText: 'Context' })).toBeVisible();
    } finally {
      if (createdId) {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
      }
    }
  });

  test('Create button stays clickable across successive creates in one session', async ({ page }) => {
    // Regression: submit() disabled #c-submit but only re-enabled it in catch,
    // so after the first successful create the button stayed disabled and a
    // second click did nothing until page reload.
    const first = `First create ${Date.now()}`;
    const second = `Second create ${Date.now()}`;
    const createdIds = [];

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      // First create
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(first);
      await page.locator('#c-submit').click();
      const firstCard = page.locator('.card', { hasText: first });
      await expect(firstCard).toBeVisible();
      createdIds.push(await firstCard.getAttribute('data-id') || '');

      // Reopen — the Create button must not be stuck disabled from the last submit
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await expect(page.locator('#c-submit')).toBeEnabled();

      // Second create via a real click (not Enter) must actually create a ticket
      await page.locator('#c-title').fill(second);
      await page.locator('#c-submit').click();
      const secondCard = page.locator('.card', { hasText: second });
      await expect(secondCard).toBeVisible();
      createdIds.push(await secondCard.getAttribute('data-id') || '');
    } finally {
      for (const id of createdIds) {
        if (id) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    }
  });

  test('create-ticket textarea has updated placeholder', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    await page.locator('#btn-create').click();
    await page.waitForSelector('#create-modal', { timeout: 3000 });

    const textarea = page.locator('#create-modal textarea');
    const placeholder = await textarea.getAttribute('placeholder');
    expect(placeholder).not.toMatch(/^Description$/i);
  });

  test('New Ticket Eval-only toggle is CI-gated and writes gate: eval (t-4e57)', async ({ page }) => {
    const title = `Eval-only test ${Date.now()}`;
    let createdId = '';
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });

      const evalPill = page.locator('#c-gate-eval');
      // CI off → Eval-only is disabled (mode only meaningful with CI)
      await expect(evalPill).toBeDisabled();

      // Turn CI on → Eval-only becomes enabled
      await page.locator('#c-ci').click();
      await expect(evalPill).toBeEnabled();

      // Enable Eval-only, then create
      await evalPill.click();
      await expect(evalPill).toHaveClass(/active/);
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      // The created ticket.md carries both ci: true and gate: eval
      const tm = fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md'), 'utf8');
      expect(tm).toMatch(/^ci: true$/m);
      expect(tm).toMatch(/^gate: eval$/m);
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('New Ticket Demo toggle writes demo: true and shows the DEMO card badge (t-dfaa)', async ({ page }) => {
    const title = `Demo toggle test ${Date.now()}`;
    let createdId = '';
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });

      // Demo is independent of CI — enabled without turning CI on
      const demoPill = page.locator('#c-demo');
      await expect(demoPill).toBeEnabled();
      await demoPill.click();
      await expect(demoPill).toHaveClass(/active/);

      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      // Frontmatter carries demo: true
      const tm = fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md'), 'utf8');
      expect(tm).toMatch(/^demo: true$/m);

      // The card renders the DEMO badge
      await expect(card.locator('.demo-badge')).toBeVisible();
      await expect(card.locator('.demo-badge')).toHaveText('DEMO');
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('sidebar type legend shows the type_outcome ratio once per type, not repeated on cards (t-5a09)', async ({ page }) => {
    const stamp = Date.now();
    // Short type name, matching real-world type length (bug/feature/task/chore/epic, <=7
    // chars): the legend's grid column width is shared across all rows and sizes to the
    // longest type name on the board, so an unrealistically long synthetic type (e.g. a full
    // "outcometest<timestamp>" string) would widen/wrap the row on its own — a test-fixture
    // artifact, not a regression in the fix under test (verified against real board data,
    // which stays single-line at this dot design).
    const type = `t${stamp.toString(36).slice(-4)}`;
    const cleanId = `t-oc-clean-${stamp}`;
    const reworkId = `t-oc-rework-${stamp}`;
    const openId = `t-oc-open-${stamp}`;
    const openId2 = `t-oc-open2-${stamp}`;
    const ids = [cleanId, reworkId, openId, openId2];

    const writeTicket = (id, status, extraFrontmatter = '') => {
      const dir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        `status: ${status}`,
        `type: ${type}`,
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        extraFrontmatter,
        '---',
        '',
        `# ${id}`,
        '',
      ].filter(Boolean).join('\n'));
    };

    try {
      writeTicket(cleanId, 'closed', 'eval_fail_count: 0');
      writeTicket(reworkId, 'closed', 'eval_fail_count: 3');
      writeTicket(openId, 'open');
      writeTicket(openId2, 'open');

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      // No per-card badge anywhere on the board — the whole point of this change (t-5a09) —
      // covers both same-type open cards, not just one.
      await expect(page.locator(`.card[data-id="${openId}"]`)).toBeVisible();
      await expect(page.locator(`.card[data-id="${openId2}"]`)).toBeVisible();
      await expect(page.locator('.card .outcome-dot')).toHaveCount(0);

      // Sidebar legend shows the ratio exactly once for this type, as a compact dot
      // (not a wrapping text pill — the narrow legend column can't fit "N/M clean" inline).
      const legendItem = page.locator('.sidebar-donut-legend-item', { hasText: type });
      await expect(legendItem).toBeVisible();
      const dot = legendItem.locator('.outcome-dot');
      await expect(dot).toHaveCount(1);
      await expect(dot).toBeVisible();
      await expect(dot).toHaveAttribute('data-tooltip', /1 of 2 past .+ closed/);
      await expect(dot).toHaveAttribute('aria-label', /1 of 2 past .+ closed/);
      // hover shows the shared custom tooltip with the full detail text
      await dot.hover();
      const tooltip = page.locator('#hover-tooltip');
      await expect(tooltip).toHaveClass(/visible/);
      await expect(tooltip).toContainText('1 of 2 past');
      await page.mouse.move(0, 0);
      await expect(tooltip).not.toHaveClass(/visible/);
      // rendered-output check: the mixed-result color variant, not the good/green one
      await expect(dot).toHaveClass(/outcome-mixed/);
      // no line-wrap regression: the legend item has `display: contents` (no box of its own),
      // so check its rendered type-name+dot wrapper span instead — that's the actual box that
      // would grow tall if the dot didn't fit inline.
      const typeSpan = legendItem.locator('span', { hasText: type }).last();
      const typeBox = await typeSpan.boundingBox();
      // single line is 21px in production (verified against real board data); a wrap is ~42px
      expect(typeBox.height).toBeLessThan(30);
    } finally {
      for (const id of ids) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Set up CI gate writes canon-gate.yml and refuses on re-click (t-344e)', async ({ page }) => {
    const wf = path.join(PROJECT_ROOT, '.github', 'workflows', 'canon-gate.yml');
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-ci-setup').click();
      await expect(page.locator('#drop-toast')).toContainText('canon-gate.yml');
      await expect.poll(() => fs.existsSync(wf)).toBe(true);

      // Re-click → refuse-on-exists surfaced
      await page.locator('#btn-ci-setup').click();
      await expect(page.locator('#drop-toast')).toContainText('already exists');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.github'), { recursive: true, force: true });
    }
  });

  test('Research doc type available in + button and shows tab when present', async ({ page }) => {
    const title = `Research tab test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      // Create ticket with acceptance + plan + research docs
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      // Write research.md directly so the board can pick it up
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', createdId);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'research.md'), [
        '# Research',
        `Ticket: \`${createdId}\``,
        '## Objective',
        'Test that the board renders a Research tab.',
      ].join('\n'));

      // Reload so the board picks up the new file
      await page.reload();
      await page.waitForLoadState('networkidle');

      await page.locator('.card', { hasText: title }).click();
      await expect(page.locator('#m-docs .doc-tab', { hasText: 'Research' })).toBeVisible();
    } finally {
      if (createdId) {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
      }
    }
  });

  test('+ button offers Research doc type', async ({ page }) => {
    const title = `Research plus button test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      await card.click();

      // Open the + doc menu and confirm Research is listed
      await page.locator('#btn-new-doc').click();
      await expect(page.locator('#m-body .doc-type-card[data-slug="research"]')).toBeVisible();
    } finally {
      if (createdId) {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
      }
    }
  });

  test('Save button appears immediately after creating a new companion doc (t-c58c)', async ({ page }) => {
    const title = `New-doc save button test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      await card.click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);

      await page.locator('#btn-new-doc').click();
      await page.locator('.doc-type-card[data-slug="plan"]').click();
      await page.locator('#act-picker-edit').click();
      await expect(page.locator('#m-edit-area')).toBeVisible();

      // The bug: Save/Cancel were missing, and the stale +New-doc/Edit buttons stuck around
      // because renderModalDocs ran before modalState.editMode was set to true.
      await expect(page.locator('#btn-save-top')).toBeVisible();
      await expect(page.locator('#btn-cancel-top')).toBeVisible();
      await expect(page.locator('#btn-new-doc')).toHaveCount(0);
      await expect(page.locator('#btn-edit-doc')).toHaveCount(0);

      page.on('dialog', dialog => { throw new Error(`unexpected dialog: ${dialog.message()}`); });
      const template = await page.locator('#m-edit-area').inputValue();
      await page.locator('#m-edit-area').fill(template.replace('## Approach', '## Approach\npasted plan content'));
      await page.locator('#btn-save-top').click();
      await expect(page.locator('#m-edit-area')).toBeHidden();

      const planContent = fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'plan.md'), 'utf8');
      expect(planContent).toContain('pasted plan content');
    } finally {
      if (createdId) {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
      }
    }
  });

  test('archive button: Done card can be archived; archived ticket appears in search but not board columns', async ({ page }) => {
    const title = `Archive test ${Date.now()}`;
    const createdId = `t-arch-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', createdId);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${createdId}`,
        'status: closed',
        'type: task',
        'priority: 2',
        'created: 2026-06-01T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      // Search by ID to surface the card (Done column is capped at 5 visible cards)
      await page.locator('#board-search').fill(createdId);
      await page.waitForTimeout(200);

      // Archive button should appear even when the hover starts over the card type badge.
      const doneCard = page.locator('.col-done .card[data-id="' + createdId + '"]');
      await expect(doneCard).toBeVisible({ timeout: 8000 });
      const badgeBox = await doneCard.locator('.type-badge').boundingBox();
      expect(badgeBox).not.toBeNull();
      await page.mouse.move(badgeBox.x + badgeBox.width / 2, badgeBox.y + badgeBox.height / 2);
      const archiveBtn = doneCard.locator('.card-archive');
      await expect(archiveBtn).toBeVisible();
      await archiveBtn.click();

      // Confirmation toast should appear — click Confirm to proceed
      const toast = page.locator('#drop-toast');
      await expect(toast).toContainText('Archive ticket');
      await expect(toast).toContainText('Click to confirm');
      await toast.locator('.toast-confirm').click();
      await page.waitForLoadState('networkidle');

      // Clear search — card should no longer appear in Done column
      await page.locator('#board-search').fill('');
      await page.waitForTimeout(200);
      await expect(page.locator('.col-done .card[data-id="' + createdId + '"]')).not.toBeVisible();

      // Header archived count should appear
      await expect(page.locator('#h-archived-stat')).toBeVisible();

      // Search should find the archived ticket
      await page.locator('#board-search').fill(createdId);
      await page.waitForTimeout(300);
      await expect(page.locator('#board-search-count')).toContainText('1');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('CI badge: shown for ci: true, absent for ci: false/unset', async ({ page }) => {
    const stamp = Date.now();
    const onId = `t-cion-${stamp}`;
    const offId = `t-cioff-${stamp}`;

    try {
      for (const [id, ci] of [[onId, 'ci: true'], [offId, null]]) {
        const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
        fs.mkdirSync(ticketDir, { recursive: true });
        fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
          '---',
          `id: ${id}`,
          'status: open',
          'type: task',
          'priority: 2',
          'created: 2026-06-01T00:00:00Z',
          ...(ci ? [ci] : []),
          '---',
          '',
          `# CI badge test ${id}`,
          '',
        ].join('\n'));
      }

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(onId);
      await page.waitForTimeout(200);
      const onCard = page.locator('.card[data-id="' + onId + '"]');
      await expect(onCard).toBeVisible({ timeout: 8000 });
      await expect(onCard.locator('.ci-badge')).toBeVisible();
      await expect(onCard.locator('.ci-badge')).toHaveText('CI');

      await page.locator('#board-search').fill(offId);
      await page.waitForTimeout(200);
      const offCard = page.locator('.card[data-id="' + offId + '"]');
      await expect(offCard).toBeVisible({ timeout: 8000 });
      await expect(offCard.locator('.ci-badge')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', onId), { recursive: true, force: true });
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', offId), { recursive: true, force: true });
    }
  });

  test('search finds a ticket by model mention in acceptance.md, not just title/body', async ({ page }) => {
    const stamp = Date.now();
    const createdId = `t-model-${stamp}`;
    const title = `Model search test ${stamp}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', createdId);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${createdId}`,
        'status: open',
        'type: task',
        'priority: 2',
        'created: 2026-06-08T00:00:00Z',
        '---',
        '',
        `# ${title}`,
        '',
      ].join('\n'));
      // Title/body never mention the model — only acceptance.md's Wrapup Gates row does.
      // The Criteria line below mentions the (model: X) convention itself as prose
      // (t-1720 regression) — it must NOT be searchable, only the real Wrapup Gates row.
      fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), [
        '# Acceptance',
        '',
        '## Criteria',
        '- [x] Has criteria',
        '- [x] Describes the convention itself, e.g. `(model: mistral)`, as prose — not a real usage',
        '',
        '## Test Plan',
        '- [x] Has tests',
        '',
        '## Wrapup Gates',
        '| Gate | Status | Reason |',
        '|------|--------|--------|',
        '| eval | ran | verdict: pass (model: haiku) |',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill('haiku');
      await page.waitForTimeout(300);
      await expect(page.locator(`.card[data-id="${createdId}"]`)).toBeVisible({ timeout: 8000 });

      // t-1720 regression: the Criteria prose mentions "mistral" via the (model: X)
      // pattern, but only inside ## Criteria, not ## Wrapup Gates — must not be searchable.
      await page.locator('#board-search').fill('mistral');
      await page.waitForTimeout(300);
      await expect(page.locator(`.card[data-id="${createdId}"]`)).not.toBeVisible();

      await page.locator('#board-search').fill('a-term-that-appears-nowhere-xyz');
      await page.waitForTimeout(300);
      await expect(page.locator(`.card[data-id="${createdId}"]`)).not.toBeVisible();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('modal next and previous stay in the same status lane sorted by newest first', async ({ page }) => {
    const stamp = Date.now();
    const tickets = [
      { id: `t-nav-old-${stamp}`, title: `Nav old ${stamp}`, status: 'closed', created: '2026-01-01T00:00:00Z' },
      { id: `t-nav-mid-${stamp}`, title: `Nav mid ${stamp}`, status: 'closed', created: '2026-02-01T00:00:00Z' },
      { id: `t-nav-new-${stamp}`, title: `Nav new ${stamp}`, status: 'closed', created: '2026-03-01T00:00:00Z' },
      { id: `t-nav-open-${stamp}`, title: `Nav open ${stamp}`, status: 'open', created: '2026-04-01T00:00:00Z' },
    ];

    try {
      for (const ticket of tickets) {
        const ticketDir = path.join(PROJECT_ROOT, '.tickets', ticket.id);
        fs.mkdirSync(ticketDir, { recursive: true });
        fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
          '---',
          `id: ${ticket.id}`,
          `status: ${ticket.status}`,
          'type: task',
          'priority: 2',
          `created: ${ticket.created}`,
          '---',
          '',
          `# ${ticket.title}`,
          '',
        ].join('\n'));
        fs.writeFileSync(path.join(ticketDir, 'acceptance.md'), [
          '# Acceptance',
          '',
          '## Criteria',
          '- [x] Done',
          '',
          '## Test Plan',
          '- [x] Tested',
          '',
        ].join('\n'));
      }

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(`Nav mid ${stamp}`);
      await page.locator(`.col-done .card[data-id="t-nav-mid-${stamp}"]`).click();
      await expect(page.locator('#m-title')).toHaveText(`Nav mid ${stamp}`);

      await page.locator('#btn-ticket-prev').click();
      await expect(page.locator('#m-title')).toHaveText(`Nav new ${stamp}`);

      await page.locator('#btn-ticket-next').click();
      await expect(page.locator('#m-title')).toHaveText(`Nav mid ${stamp}`);

      await page.locator('#btn-ticket-next').click();
      await expect(page.locator('#m-title')).toHaveText(`Nav old ${stamp}`);

      await expect(page.locator('#m-title')).not.toHaveText(`Nav open ${stamp}`);
    } finally {
      for (const ticket of tickets) {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', ticket.id), { recursive: true, force: true });
      }
    }
  });

  test('visual image referenced via markdown renders inline in the doc', async ({ page }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(path.join(ticketDir, 'visuals'), { recursive: true });
      // 1x1 transparent PNG — real, decodable bytes, not just a magic-number stub,
      // so the browser actually loads it rather than firing an error event.
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
        'base64'
      );
      fs.writeFileSync(path.join(ticketDir, 'visuals', 'chosen.png'), png);

      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-07-06T00:00:00Z',
        '---',
        '',
        '# Mockup render test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        `Ticket: \`${id}\``,
        '',
        '## Sign-off',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Chosen visual direction:',
        '',
        '![Chosen visual](visuals/chosen.png)',
        '',
      ].join('\n'));

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Plan');

      const img = page.locator('#m-body img.doc-visual-img');
      await expect(img).toBeVisible();
      await expect(img).toHaveAttribute('src', `/api/ticket-image/${id}/visuals/chosen.png`);
      // Confirm the browser actually decoded real image bytes, not a broken-image icon.
      await expect.poll(() => img.evaluate(el => el.naturalWidth)).toBeGreaterThan(0);

      // Raw markdown syntax must not leak through as literal text once rendered.
      await expect(page.locator('#m-body')).not.toContainText('![Chosen visual]');
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('pasting a clipboard image into New Ticket lands it in visuals/ and renders (t-626d)', async ({ page }) => {
    const title = `Paste image test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);

      await pasteImageIntoElement(page, '#c-body');
      await expect(page.locator('#c-body')).toHaveValue(/!\[pasted-1\]\(pending:1\)/);

      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      expect(createdId).toBeTruthy();

      const ticketMd = path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md');
      await expect.poll(() => fs.existsSync(ticketMd) ? fs.readFileSync(ticketMd, 'utf8') : '')
        .toMatch(/!\[pasted-1\]\(visuals\/pasted-1\.png\)/);
      const ticketBody = fs.readFileSync(ticketMd, 'utf8');
      expect(ticketBody).not.toContain('pending:1');
      expect(fs.existsSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'visuals', 'pasted-1.png'))).toBe(true);

      await card.click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
      const img = page.locator('#m-body img.doc-visual-img');
      await expect(img).toBeVisible();
      await expect(img).toHaveAttribute('src', `/api/ticket-image/${createdId}/visuals/pasted-1.png`);
      await expect.poll(() => img.evaluate(el => el.naturalWidth)).toBeGreaterThan(0);
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('pasting two images into the same New Ticket produces two distinct files (t-626d)', async ({ page }) => {
    const title = `Paste two images test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);

      await pasteImageIntoElement(page, '#c-body');
      await pasteImageIntoElement(page, '#c-body');
      await expect(page.locator('#c-body')).toHaveValue(/!\[pasted-1\]\(pending:1\)/);
      await expect(page.locator('#c-body')).toHaveValue(/!\[pasted-2\]\(pending:2\)/);

      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      const visualsDir = path.join(PROJECT_ROOT, '.tickets', createdId, 'visuals');
      await expect.poll(() => fs.existsSync(visualsDir) ? fs.readdirSync(visualsDir).sort() : [])
        .toEqual(['pasted-1.png', 'pasted-2.png']);
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('pasting an image into edit mode inserts a real embed without reload (t-626d)', async ({ page }) => {
    const title = `Paste edit mode test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-body').fill('## Notes\nExisting text.');
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      await card.click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
      await page.locator('#btn-edit-doc').click();
      await expect(page.locator('#m-edit-area')).toBeVisible();

      await pasteImageIntoElement(page, '#m-edit-area');
      await expect(page.locator('#m-edit-area')).toHaveValue(/Uploading pasted-1…/);
      await expect.poll(() => page.locator('#m-edit-area').inputValue())
        .toMatch(/!\[pasted-1\]\(visuals\/pasted-1\.png\)/);

      page.on('dialog', dialog => { throw new Error(`unexpected dialog: ${dialog.message()}`); });
      await page.locator('#btn-save-top').click();
      await expect(page.locator('#m-edit-area')).toBeHidden();

      const ticketBody = fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md'), 'utf8');
      expect(ticketBody).toMatch(/!\[pasted-1\]\(visuals\/pasted-1\.png\)/);
      expect(fs.existsSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'visuals', 'pasted-1.png'))).toBe(true);
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('pasting an image into a companion doc (plan.md) edit mode inserts a real embed (t-626d)', async ({ page }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---', `id: ${id}`, 'status: in_progress', 'type: task', 'priority: 2',
        'created: 2026-07-21T00:00:00Z', '---', '', '# Companion doc paste test', '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan', '', `Ticket: \`${id}\``, '', '## Sign-off', '- [x] Plan approved',
        '', '## Approach', 'Existing approach text.', '', '## Decisions', '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Plan');
      await page.locator('#btn-edit-doc').click();
      // enterEditMode fetches the companion doc's content asynchronously and
      // overwrites #m-edit-area's value once it resolves — wait for the real
      // content, not just visibility, or a paste lands before the fetch wipes it.
      await expect(page.locator('#m-edit-area')).toHaveValue(/Existing approach text\./);

      await pasteImageIntoElement(page, '#m-edit-area');
      await expect.poll(() => page.locator('#m-edit-area').inputValue())
        .toMatch(/!\[pasted-1\]\(visuals\/pasted-1\.png\)/);

      page.on('dialog', dialog => { throw new Error(`unexpected dialog: ${dialog.message()}`); });
      await page.locator('#btn-save-top').click();
      await expect(page.locator('#m-edit-area')).toBeHidden();

      const planContent = fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8');
      expect(planContent).toMatch(/!\[pasted-1\]\(visuals\/pasted-1\.png\)/);
      expect(fs.existsSync(path.join(ticketDir, 'visuals', 'pasted-1.png'))).toBe(true);
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('a failed visual upload in New Ticket leaves a visible marker, not a dangling pending: reference (t-626d)', async ({ page }) => {
    const title = `Paste upload failure test ${Date.now()}`;
    let createdId = '';

    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      // Force the upload endpoint to fail so the create-flow's failure path runs.
      await page.route('**/api/ticket/*/visual', route => route.fulfill({
        status: 200, contentType: 'application/json', body: JSON.stringify({ ok: false }),
      }));

      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await pasteImageIntoElement(page, '#c-body');
      await page.locator('#c-submit').click();

      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';

      const ticketMd = path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md');
      await expect.poll(() => fs.existsSync(ticketMd) ? fs.readFileSync(ticketMd, 'utf8') : '')
        .toMatch(/!\[paste failed\]\(\)/);
      const ticketBody = fs.readFileSync(ticketMd, 'utf8');
      expect(ticketBody).not.toContain('pending:1');
      expect(fs.existsSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'visuals'))).toBe(false);
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('pasting plain text is unaffected by the image-paste handler (t-626d)', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    await page.locator('#btn-create').click();
    await page.waitForSelector('#create-modal', { timeout: 3000 });

    await page.evaluate(() => {
      const el = document.querySelector('#c-body');
      el.focus();
      const dt = new DataTransfer();
      dt.setData('text/plain', 'hello world');
      el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    });

    await expect(page.locator('#c-body')).not.toHaveValue(/pending:|visuals\//);
  });

  test('a crafted ticket-image path is rejected, not served', async ({ request }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(path.join(ticketDir, 'visuals'), { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: open',
        'type: task',
        'priority: 2',
        'created: 2026-07-06T00:00:00Z',
        '---',
        '',
        '# Traversal rejection test',
        '',
      ].join('\n'));

      const traversal = await request.get(`${BASE}/api/ticket-image/${id}/../../../../etc/passwd`);
      expect(traversal.status()).toBe(404);

      const wrongExt = await request.get(`${BASE}/api/ticket-image/${id}/ticket.md`);
      expect(wrongExt.status()).toBe(404);

      const missing = await request.get(`${BASE}/api/ticket-image/${id}/visuals/does-not-exist.png`);
      expect(missing.status()).toBe(404);
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('a quote-breaking visual src cannot inject a live HTML attribute', async ({ page }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-07-06T00:00:00Z',
        '---',
        '',
        '# Src injection rejection test',
        '',
      ].join('\n'));
      // No whitespace in the payload — the image regex's src group excludes
      // \s, so a space-containing payload would just fail to match at all
      // rather than exercising the attribute-escaping fix under test.
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        `Ticket: \`${id}\``,
        '',
        '## Sign-off',
        '- [x] Plan approved',
        '',
        '## Approach',
        '![x](http://evil.example/x.png"onerror="window.__xss_fired=true"//)',
        '',
      ].join('\n'));

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Plan');
      await expect(page.locator('#m-body img.doc-visual-img')).toBeVisible();

      const fired = await page.evaluate(() => window.__xss_fired);
      expect(fired).toBeUndefined();
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('markdown syntax shown as an inline-code example stays literal, real syntax still renders', async ({ page }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(path.join(ticketDir, 'visuals'), { recursive: true });
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
        'base64'
      );
      fs.writeFileSync(path.join(ticketDir, 'visuals', 'real.png'), png);

      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-07-06T00:00:00Z',
        '---',
        '',
        '# Inline-code protection test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        `Ticket: \`${id}\``,
        '',
        '## Sign-off',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Documentation showing syntax as code: `![alt](src)` should stay literal.',
        'Also test bold-as-code: `**not bold**` should stay literal.',
        'Also test pipe-in-code: `a|b|c` should stay literal, not break a table.',
        'A real image reference: ![real visual](visuals/real.png)',
        '',
        '## Eval-style table',
        '| Criterion | Status | Evidence |',
        '|---|---|---|',
        "| Uses `checkbox.className = 'x'` | pass | `file.py:10` |",
        '',
      ].join('\n'));

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Plan');

      const body = page.locator('#m-body');
      // The active-tab class flips synchronously in the click handler, before the
      // doc content's own async fetch resolves — wait for real content, not just
      // the tab state, or this reads an empty/stale body under load (t-c58c).
      await expect(body.locator('code.doc-code').first()).toBeVisible();
      const codeTexts = await body.locator('code.doc-code').allTextContents();
      expect(codeTexts).toContain('![alt](src)');
      expect(codeTexts).toContain('**not bold**');
      expect(codeTexts).toContain('a|b|c');

      const boldTexts = await body.locator('strong').allTextContents();
      expect(boldTexts).not.toContain('not bold');

      const img = body.locator('img.doc-visual-img');
      await expect(img).toBeVisible();
      await expect.poll(() => img.evaluate(el => el.naturalWidth)).toBeGreaterThan(0);

      await expect(body.locator('table.doc-table')).toBeVisible();
      await expect(body.locator('table.doc-table td.status-pass')).toBeVisible();
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('backslash-escaped nested backticks in a citation stay literal, no broken image', async ({ page }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-07-06T00:00:00Z',
        '---',
        '',
        '# Nested-backtick citation test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        `Ticket: \`${id}\``,
        '',
        '## Sign-off',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Reproduces t-6ea4\'s exact broken-render pattern: an evidence citation',
        'quoting source text that itself contains backticks, escaped with a',
        'backslash so the outer citation stays one span.',
        '',
        '## Evidence table',
        '| Criterion | Status | Evidence |',
        '|---|---|---|',
        '| Uses embed | pass | `standards/ticket-layout.md:1 — "already-saved \\`visuals/x.png\\` candidate, must be a real markdown image embed — \\`![alt](visuals/ghost.png)\\` — never a bare mention."` |',
        '',
      ].join('\n'));

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Plan');

      const body = page.locator('#m-body');
      await expect(body.locator('code.doc-code').first()).toBeVisible();

      // The whole citation must render as one code span with the backslash
      // stripped and the inner backticks restored as plain characters — not
      // as a broken <img> pointing at a nonexistent visuals/ghost.png.
      const codeTexts = await body.locator('code.doc-code').allTextContents();
      const citation = codeTexts.find(t => t.includes('visuals/ghost.png'));
      expect(citation).toBeTruthy();
      expect(citation).toContain('`visuals/x.png`');
      expect(citation).toContain('`![alt](visuals/ghost.png)`');
      expect(citation).not.toContain('\\`');

      await expect(body.locator('img.doc-visual-img')).toHaveCount(0);
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('Why mode caps results at 10 and shows a "+N more, older" line', async ({ page }) => {
    // Why mode needs real git commits referencing ticket IDs, which the
    // shared BASE server's fixture doesn't have — spin up a dedicated git
    // repo + server for just this test rather than polluting real history.
    const fixtureDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'why-cap-'));
    let serverProcess;
    try {
      const git = (...args) => execFileSync('git', args, { cwd: fixtureDir });
      git('init', '-q');
      git('config', 'user.email', 'test@test.com');
      git('config', 'user.name', 'test');

      fs.writeFileSync(path.join(fixtureDir, 'shared.js'), 'hello\n');
      git('add', 'shared.js');
      git('commit', '-q', '-m', 't-aaa1 initial add');
      fs.mkdirSync(path.join(fixtureDir, '.tickets', 't-aaa1'), { recursive: true });
      fs.writeFileSync(path.join(fixtureDir, '.tickets', 't-aaa1', 'ticket.md'), [
        '---', 'id: t-aaa1', 'status: closed', 'type: task', 'priority: 2',
        'created: 2026-01-01T00:00:00Z', '---', '', '# Initial add', '',
      ].join('\n'));

      const suffixes = ['bbb2', 'ccc3', 'ddd4', 'eee5', 'fff6', 'ggg7', 'hhh8', 'iii9', 'jjj0', 'kkk1', 'lll2', 'mmm3'];
      for (const s of suffixes) {
        fs.appendFileSync(path.join(fixtureDir, 'shared.js'), `change ${s}\n`);
        git('add', 'shared.js');
        git('commit', '-q', '-m', `t-${s} update shared.js`);
        fs.mkdirSync(path.join(fixtureDir, '.tickets', `t-${s}`), { recursive: true });
        fs.writeFileSync(path.join(fixtureDir, '.tickets', `t-${s}`, 'ticket.md'), [
          '---', `id: t-${s}`, 'status: closed', 'type: task', 'priority: 2',
          'created: 2026-01-01T00:00:00Z', '---', '', `# Update ${s}`, '',
        ].join('\n'));
      }

      const port = await new Promise((resolve) => {
        const srv = net.createServer();
        srv.listen(0, '127.0.0.1', () => {
          const p = srv.address().port;
          srv.close(() => resolve(p));
        });
      });

      const serverLog = fs.openSync(path.join(fixtureDir, 'server.log'), 'a');
      const canonRoot = path.join(__dirname, '..');
      serverProcess = spawn('python3', [path.join(canonRoot, 'tools', 'sprint-check-app', 'server.py'), String(port)], {
        cwd: fixtureDir,
        env: { ...process.env, SPRINT_CHECK_ROOT: fixtureDir },
        stdio: ['ignore', serverLog, serverLog],
      });
      const dedicatedBase = `http://127.0.0.1:${port}`;
      await expect.poll(async () => {
        try {
          const r = await page.request.get(`${dedicatedBase}/api/tickets`);
          return r.status();
        } catch {
          return 0;
        }
      }, { timeout: 5000 }).toBe(200);

      await page.goto(dedicatedBase);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill('why:shared.js');
      await page.waitForSelector('#why-results.visible', { timeout: 5000 });

      await expect(page.locator('.why-result')).toHaveCount(10);
      await expect(page.locator('.why-result-more')).toHaveText('+3 more, older');
    } finally {
      if (serverProcess) serverProcess.kill();
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
  });

  test('model tier control is disabled until Sign-off has a real Tier line', async ({ page }) => {
    const id = `t-model-tier-unfilled-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Model tier unfilled test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        '<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->',
        '',
        '- [ ] Plan approved',
        '',
        '## Approach',
        'Not filled yet.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      const select = page.locator('.model-tier-select');
      await expect(select).toBeVisible();
      await expect(select).toBeDisabled();
      await expect(select).toHaveAttribute('title', /Fill in Tier\/Risk/);

      // Combined Sign-off form: Tier/Risk render with defaults even though
      // Model tier stays disabled (no Tier line exists yet).
      await expect(page.locator('.signoff-tier-select')).toHaveValue('normal');
      const risk = page.locator('.signoff-risk-input');
      await expect(risk).toHaveValue('');
      await expect(risk).toHaveAttribute('placeholder', /blast radius/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('signoff Tier dropdown renders bugfix as a first-class option', async ({ page }) => {
    const id = `t-signoff-tier-bugfix-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: bug',
        'priority: 2',
        'created: 2026-07-25T00:00:00Z',
        '---',
        '',
        '# Bugfix tier board option',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: bugfix | Risk: single logic file + covering test',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Fix the off-by-one.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      // Tier: bugfix must be parseable → controls render, dropdown shows the bugfix
      // value, and the option carries the correct "Bugfix" label (not "Normal").
      const tier = page.locator('.signoff-tier-select');
      await expect(tier).toBeVisible();
      await expect(tier).toHaveValue('bugfix');
      await expect(tier.locator('option[value="bugfix"]')).toHaveText('Bugfix');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('signoff Tier/Risk form writes the base line and enables Model tier after', async ({ page }) => {
    const id = `t-signoff-base-write-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Signoff base write test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        '<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->',
        '',
        '- [ ] Plan approved',
        '',
        '## Approach',
        'Not filled yet.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      await expect(page.locator('.model-tier-select')).toBeDisabled();

      const risk = page.locator('.signoff-risk-input');
      await risk.fill('greenfield, client-only — low blast radius');
      await risk.blur();

      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: greenfield, client-only — low blast radius');

      // After the re-render, Model tier should now be enabled.
      await expect(page.locator('.model-tier-select')).toBeEnabled();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('selecting a Tier with Risk empty warns instead of silently dropping the change', async ({ page }) => {
    const id = `t-signoff-tier-warn-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Signoff tier warn test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        '<!-- Fill in: Tier: <tier> | Risk: <blast radius / key risks, one line> -->',
        '',
        '- [ ] Plan approved',
        '',
        '## Approach',
        'Not filled yet.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      const risk = page.locator('.signoff-risk-input');
      const warning = page.locator('.signoff-risk-warning');
      await expect(warning).toBeHidden();

      // Select a Tier with Risk still empty — no write should fire.
      const planBefore = fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8');
      await page.locator('.signoff-tier-select').selectOption('high-risk');
      await expect(warning).toBeVisible();
      await expect(risk).toHaveClass(/signoff-risk-input--needs-value/);
      await page.waitForTimeout(300); // give a would-be write a chance to land
      expect(fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')).toBe(planBefore);
      await expect(page.locator('.model-tier-select')).toBeDisabled();

      // Filling in Risk and blurring commits normally and clears the warning.
      await risk.fill('affects all consumers — high blast radius');
      await risk.blur();

      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: high-risk | Risk: affects all consumers — high blast radius');
      await expect(warning).toBeHidden();
      await expect(risk).not.toHaveClass(/signoff-risk-input--needs-value/);
      await expect(page.locator('.model-tier-select')).toBeEnabled();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Plan-tab Demo toggle writes/removes the demo frontmatter and updates the card badge live (t-64a0)', async ({ page }) => {
    const title = `Plan demo toggle ${Date.now()}`;
    let id = '';
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      // Create via the UI so the server assigns a real t-xxxx id (the demo endpoint's
      // strict id regex requires it — a synthetic long fixture id would be rejected).
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();
      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      id = await card.getAttribute('data-id') || '';

      // Seed a plan.md so the Plan tab renders the signoff controls (incl. the Demo toggle).
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '',
        '- [x] Plan approved', '', '## Approach', 'Filled.', '',
      ].join('\n'));

      await page.reload();
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      const toggle = page.locator('.signoff-demo-toggle');
      await expect(toggle).toHaveText('Demo/Docs/UX ✗');
      await expect(toggle).not.toHaveClass(/active/);
      await expect(page.locator(`.card[data-id="${id}"] .demo-badge`)).toHaveCount(0);

      // Toggle ON → frontmatter gains demo: true, button flips, card badge appears live
      await toggle.click();
      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'ticket.md'), 'utf8')
      ).toMatch(/^demo: true$/m);
      await expect(page.locator('.signoff-demo-toggle')).toHaveText('Demo/Docs/UX ✓');
      await expect(page.locator(`.card[data-id="${id}"] .demo-badge`)).toBeVisible();

      // Toggle OFF → demo line removed, badge gone
      await page.locator('.signoff-demo-toggle').click();
      await expect.poll(() =>
        /^demo:/m.test(fs.readFileSync(path.join(ticketDir, 'ticket.md'), 'utf8'))
      ).toBe(false);
      await expect(page.locator('.signoff-demo-toggle')).toHaveText('Demo/Docs/UX ✗');
      await expect(page.locator(`.card[data-id="${id}"] .demo-badge`)).toHaveCount(0);
    } finally {
      if (id) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('signoff form pre-fills from an existing parseable Tier/Risk/Gate model line and preserves the suffix on Tier change', async ({ page }) => {
    const id = `t-signoff-prefill-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Signoff prefill test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: high-risk | Risk: foo | Gate model: haiku',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      await expect(page.locator('.signoff-tier-select')).toHaveValue('high-risk');
      await expect(page.locator('.signoff-risk-input')).toHaveValue('foo');
      await expect(page.locator('.model-tier-select')).toHaveValue('haiku');

      // Change Tier only — the Gate model suffix must survive verbatim, and the
      // blank line separating the Tier line from the checkbox must not get eaten
      // (regression: an earlier `\s*$` in the replace regex consumed it, gluing
      // "- [x] Plan approved" directly onto the Tier line).
      await page.locator('.signoff-tier-select').selectOption('normal');
      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: foo | Gate model: haiku\n\n- [x] Plan approved');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('signoff form does not render for an unrecognized Tier value, Model tier stays independent', async ({ page }) => {
    const id = `t-signoff-trivial-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Signoff trivial tier test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: trivial | Risk: one-liner downgrade reason',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      await expect(page.locator('.signoff-tier-select')).toHaveCount(0);
      await expect(page.locator('.signoff-risk-input')).toHaveCount(0);
      // Model tier is unaffected by the unrecognized Tier value — it only
      // checks that a Tier: line exists at all.
      await expect(page.locator('.model-tier-select')).toBeEnabled();
      await expect(page.locator('#m-body')).toContainText('Tier: trivial | Risk: one-liner downgrade reason');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('signoff form preserves an unrecognized Gate model value when Risk changes', async ({ page }) => {
    const id = `t-signoff-preserve-custom-model-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Signoff preserve custom model test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: normal | Risk: foo | Gate model: session',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      await expect(page.locator('.model-tier-select')).toBeDisabled();

      const risk = page.locator('.signoff-risk-input');
      await risk.fill('bar');
      await risk.blur();

      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: bar | Gate model: session');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('signoff Tier/Risk controls are disabled on a closed ticket', async ({ page }) => {
    const id = `t-signoff-closed-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: closed',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Signoff closed test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: normal | Risk: low blast radius',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      await expect(page.locator('.signoff-tier-select')).toBeDisabled();
      await expect(page.locator('.signoff-risk-input')).toBeDisabled();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('model tier control writes and clears the Gate model suffix on Sign-off', async ({ page }) => {
    const id = `t-model-tier-write-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Model tier write test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: normal | Risk: low blast radius',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      const select = page.locator('.model-tier-select');
      await expect(select).toBeEnabled();
      await expect(select).toHaveValue('default');

      await select.selectOption('haiku');
      // Same regression as withSignoffBase: the blank line after the Tier line
      // must survive, not get glued to the checkbox below.
      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: low blast radius | Gate model: haiku\n\n- [x] Plan approved');

      // Close and re-open the ticket modal fresh, confirm it reflects the saved value.
      await page.keyboard.press('Escape');
      await expect(page.locator('#modal-overlay')).not.toHaveClass(/open/);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      const select2 = page.locator('.model-tier-select');
      await expect(select2).toHaveValue('haiku');

      await select2.selectOption('default');
      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: low blast radius\n');
      expect(fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')).not.toContain('Gate model');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('model tier control is disabled for a hand-set value it does not recognize', async ({ page }) => {
    const id = `t-model-tier-custom-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: in_progress',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Model tier custom value test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: normal | Risk: low blast radius | Gate model: session',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      const select = page.locator('.model-tier-select');
      await expect(select).toBeVisible();
      await expect(select).toBeDisabled();
      await expect(select).toHaveAttribute('title', /session/);
      // Must not have been silently reset to Default in the file.
      expect(fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')).toContain('Gate model: session');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('model tier control is disabled on a closed ticket', async ({ page }) => {
    const id = `t-model-tier-closed-${Date.now()}`;

    try {
      const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---',
        `id: ${id}`,
        'status: closed',
        'type: task',
        'priority: 2',
        'created: 2026-06-28T00:00:00Z',
        '---',
        '',
        '# Model tier closed test',
        '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan',
        '',
        '## Sign-off',
        'Tier: normal | Risk: low blast radius',
        '',
        '- [x] Plan approved',
        '',
        '## Approach',
        'Some real approach notes.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();

      const select = page.locator('.model-tier-select');
      await expect(select).toBeVisible();
      await expect(select).toBeDisabled();
      await expect(select).toHaveAttribute('title', /closed/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test.describe('headless grading trigger (t-200b)', () => {
    // These tests need `server.py` to invoke a stub instead of the real
    // `claude -p`-driving tools/sprint-headless. Point a *dedicated* server
    // (own process, own SPRINT_HEADLESS_BIN env) at a throwaway temp file
    // instead of overwriting the real tools/sprint-headless in place — the
    // prior approach relied on a same-process finally to restore the real
    // file, which can't survive an uncatchable kill mid-test (t-1781: this
    // is exactly how two evaluator subagent dispatches corrupted the real
    // file). Now nothing under tools/ is ever touched by this suite.
    let headlessServerProcess;
    let headlessBase;
    const STUB_PATH = path.join(require('os').tmpdir(), `sprint-headless-stub-${process.pid}.sh`);

    test.beforeAll(async ({ request }) => {
      fs.writeFileSync(STUB_PATH, '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
      const port = await new Promise((resolve) => {
        const srv = net.createServer();
        srv.listen(0, '127.0.0.1', () => {
          const p = srv.address().port;
          srv.close(() => resolve(p));
        });
      });
      headlessServerProcess = spawn('python3', [path.join(PROJECT_ROOT, 'tools', 'sprint-check-app', 'server.py'), String(port)], {
        cwd: PROJECT_ROOT,
        env: { ...process.env, SPRINT_HEADLESS_BIN: STUB_PATH },
        stdio: 'ignore',
      });
      headlessBase = `http://127.0.0.1:${port}`;
      await expect.poll(async () => {
        try { return (await request.get(`${headlessBase}/api/tickets`)).status(); } catch { return 0; }
      }, { timeout: 5000 }).toBe(200);
    });

    test.afterAll(() => {
      if (headlessServerProcess) headlessServerProcess.kill();
      fs.rmSync(STUB_PATH, { force: true });
    });

    function installStub(scriptBody) {
      fs.writeFileSync(STUB_PATH, scriptBody, { mode: 0o755 });
    }

    function ciTicket(id) {
      const dir = path.join(PROJECT_ROOT, '.tickets', id);
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'ticket.md'), [
        '---', `id: ${id}`, 'status: open', 'type: task', 'priority: 2',
        'created: 2026-06-01T00:00:00Z', 'ci: true', '---', '', `# ${id} headless-run test`, '',
      ].join('\n'));
    }

    test('trigger, poll, and show a PASS verdict with real output', async ({ page }) => {
      const id = 't-hlp1';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash', 'sleep 1', 'echo "stub pass output"', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        await page.locator(`.card[data-id="${id}"] .ci-run-btn`).click();
        await expect(page.locator('#modal-overlay.open')).toBeVisible();
        await page.locator('#m-headless-baseref').fill('main');
        await page.locator('#m-headless-run').click();
        await expect(page.locator('#m-headless-status')).toContainText('Running', { timeout: 3000 });
        await expect(page.locator('#m-headless-status')).toContainText('PASS', { timeout: 10000 });
        await page.locator('.headless-view-output').click();
        await expect(page.locator('.headless-output')).toContainText('stub pass output');
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('a claude -p failure surfaces its real error text, not a generic message', async ({ page }) => {
      const id = 't-hlf1';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash',
        'echo "Error: claude -p invocation failed (exit 1). Hard-failing." >&2',
        'exit 1', '',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        await page.locator(`.card[data-id="${id}"] .ci-run-btn`).click();
        await page.locator('#m-headless-baseref').fill('main');
        await page.locator('#m-headless-run').click();
        await expect(page.locator('#m-headless-status')).toContainText('FAIL', { timeout: 10000 });
        await page.locator('.headless-view-output').click();
        await expect(page.locator('.headless-output')).toContainText('claude -p invocation failed');
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('elapsed time increases while a slow run is in progress', async ({ page }) => {
      const id = 't-hle1';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash', 'sleep 8', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        await page.locator(`.card[data-id="${id}"] .ci-run-btn`).click();
        await page.locator('#m-headless-baseref').fill('main');
        await page.locator('#m-headless-run').click();
        await expect(page.locator('#m-headless-status')).toContainText('Running', { timeout: 3000 });
        const firstText = await page.locator('#m-headless-status').textContent();
        await page.waitForTimeout(3500);
        const laterText = await page.locator('#m-headless-status').textContent();
        expect(laterText).not.toBe(firstText);
        expect(laterText).toContain('Running');
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('a second trigger while one is running does not start a second subprocess', async ({ page }) => {
      const id = 't-hld1';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash',
        'echo "$$-$(date +%s%N)" >> "' + path.join(PROJECT_ROOT, '.tickets', id, 'run-markers.txt') + '"',
        'sleep 5', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        const first = await page.evaluate(async (ticketId) => {
          const r = await fetch(`/api/ticket/${ticketId}/headless-run`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ base_ref: 'main' }),
          });
          return r.json();
        }, id);
        expect(first.status).toBe('running');
        const second = await page.evaluate(async (ticketId) => {
          const r = await fetch(`/api/ticket/${ticketId}/headless-run`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ base_ref: 'main' }),
          });
          return r.json();
        }, id);
        expect(second.status).toBe('running');
        await page.waitForTimeout(6000);
        const markerPath = path.join(PROJECT_ROOT, '.tickets', id, 'run-markers.txt');
        const markers = fs.existsSync(markerPath)
          ? fs.readFileSync(markerPath, 'utf8').trim().split('\n').filter(Boolean)
          : [];
        expect(markers.length).toBe(1);
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('step flow (t-1262): idle/running/done states, click-to-expand descriptions', async ({ page }) => {
      const id = 't-hls1';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash', 'sleep 2', 'echo "stub output"', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        await page.locator(`.card[data-id="${id}"] .ci-run-btn`).click();
        await expect(page.locator('#modal-overlay.open')).toBeVisible();
        await page.waitForTimeout(400); // idle-pickup fetch in renderModalHeadless

        const steps = page.locator('#m-headless .headless-step');
        await expect(steps.nth(0)).toHaveClass(/active/);
        await expect(steps.nth(1)).not.toHaveClass(/active|done/);
        await expect(steps.nth(2)).not.toHaveClass(/active|done|fail/);

        // Click-to-expand description, per step, toggles closed on re-click.
        await steps.nth(0).click();
        await expect(page.locator('#m-headless-step-desc')).toHaveClass(/expanded/);
        await expect(page.locator('#m-headless-step-desc')).toContainText('commit SHA');
        await steps.nth(1).click();
        await expect(page.locator('#m-headless-step-desc')).toContainText('subagents');
        await steps.nth(1).click();
        await expect(page.locator('#m-headless-step-desc')).not.toHaveClass(/expanded/);

        await page.locator('#m-headless-baseref').fill('main');
        await page.locator('#m-headless-run').click();
        await expect(steps.nth(1)).toHaveClass(/active/, { timeout: 3000 });
        await expect(steps.nth(0)).toHaveClass(/done/);

        await expect(steps.nth(2)).toHaveClass(/done/, { timeout: 10000 });
        await expect(steps.nth(1)).toHaveClass(/done/);
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('step flow shows a fail-colored final step on a FAIL verdict', async ({ page }) => {
      const id = 't-hls2';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash', 'echo "stub fail output"', 'echo "HEADLESS_VERDICT: FAIL"', 'exit 1',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        await page.locator(`.card[data-id="${id}"] .ci-run-btn`).click();
        await page.waitForTimeout(400); // idle-pickup fetch in renderModalHeadless
        await page.locator('#m-headless-baseref').fill('main');
        await page.locator('#m-headless-run').click();
        await expect(page.locator('#m-headless .headless-step').nth(2)).toHaveClass(/fail/, { timeout: 10000 });
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('card-level Run button shows a custom tooltip, not the native title attribute', async ({ page }) => {
      const id = 't-hls3';
      ciTicket(id);
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        const runBtn = page.locator(`.card[data-id="${id}"] .ci-run-btn`);
        await expect(runBtn).not.toHaveAttribute('title', /.+/);
        await runBtn.hover();
        await expect(page.locator('#hover-tooltip')).toHaveClass(/visible/);
        await expect(page.locator('#hover-tooltip')).toHaveText('Run headless grading');
        await page.mouse.move(0, 0);
        await expect(page.locator('#hover-tooltip')).not.toHaveClass(/visible/);
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('card-level run button pulses while a run is in progress, and clears after it completes (t-dd51)', async ({ page }) => {
      const id = 't-hlr1';
      ciTicket(id);
      installStub([
        '#!/usr/bin/env bash', 'sleep 12', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(headlessBase);
        await page.waitForLoadState('networkidle');
        await page.evaluate(async (ticketId) => {
          await fetch(`/api/ticket/${ticketId}/headless-run`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ base_ref: 'main' }),
          });
        }, id);
        await page.locator('#board-search').fill(id);
        const runBtn = page.locator(`.card[data-id="${id}"] .ci-run-btn`);
        await expect(runBtn).toHaveClass(/running/, { timeout: 20000 });
        await expect(runBtn).not.toHaveClass(/running/, { timeout: 20000 });
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });
  });
});

test.describe('gherkin scenarios in acceptance (t-6e32)', () => {
  const DISCOUNT_ACCEPTANCE = [
    '# Acceptance',
    '',
    '## Criteria',
    '- [ ] **Valid code above minimum applies the discount**',
    '```gherkin',
    'Scenario: Valid code above minimum applies the discount',
    '  Given cart_total 120.00',
    '  And code "SAVE20"',
    '  When discount is applied',
    '  Then applied is true',
    '  And final_total is 96.00',
    '',
    'Scenario: Valid code below minimum is rejected',
    '  Given cart_total 40.00',
    '  When discount is applied',
    '  Then applied is false',
    '',
    'Scenario: Unknown code is rejected',
    '  Given cart_total 200.00',
    '  When discount is applied',
    '  Then applied is false',
    '```',
    '',
    '## Test Plan',
    '- [x] (cd examples/dsl-discount-spec && python dsl_runner.py specs/discount.feature) exits 0',
    '',
    '## QA',
    '- [x] Tested locally',
    '',
  ].join('\n');

  function makeTicket(id, acceptance) {
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ticket.md'), [
      '---', `id: ${id}`, 'status: in_progress', 'type: feature', 'priority: 2',
      'created: 2026-07-27T00:00:00Z', '---', '', '# Gherkin render test', '',
    ].join('\n'));
    fs.writeFileSync(path.join(dir, 'acceptance.md'), acceptance.replace('# Acceptance\n', `# Acceptance\nTicket: \`${id}\`\n`));
  }

  async function openAcceptance(page, id) {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"]`).click();
    await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
    await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
    await expect(page.locator('.doc-tab.active')).toHaveText('Acceptance');
  }

  test('a ```gherkin block renders as a distinct scenario panel with highlighted keywords, in dark and light (C2/C3/C4)', async ({ page }) => {
    const id = `t-gk-render-${Date.now()}`;
    try {
      makeTicket(id, DISCOUNT_ACCEPTANCE);
      await openAcceptance(page, id);

      const body = page.locator('#m-body');
      const panel = body.locator('.doc-scenario');
      await expect(panel).toHaveCount(1);

      // C2: literal fence markers must not leak; keywords highlighted; 3 scenarios.
      await expect(body).not.toContainText('```gherkin');
      await expect(panel).toContainText('Scenario: Valid code above minimum applies the discount');
      await expect(panel.locator('.doc-scenario-kw', { hasText: /^Scenario$/ })).toHaveCount(3);
      expect(await panel.locator('.doc-scenario-kw', { hasText: /^Given$/ }).count()).toBeGreaterThanOrEqual(3);

      // C4: the checkbox criterion above renders with a check marker.
      await expect(body.locator('.doc-check-marker').first()).toBeVisible();

      // C3: each theme drives a distinct panel background via its --scenario-bg var.
      // The board's default theme varies, so set each explicitly rather than assume one.
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
      const darkBg = await panel.evaluate(el => getComputedStyle(el).backgroundColor);
      const darkDocBg = await body.evaluate(el => getComputedStyle(el).backgroundColor);
      expect(darkBg).toBe('rgb(25, 26, 39)');
      expect(darkBg).not.toBe(darkDocBg);
      const darkKw = await panel.locator('.doc-scenario-kw').first().evaluate(el => getComputedStyle(el).color);
      expect(darkKw).toBe('rgb(217, 140, 192)');

      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
      const lightBg = await panel.evaluate(el => getComputedStyle(el).backgroundColor);
      const lightDocBg = await body.evaluate(el => getComputedStyle(el).backgroundColor);
      expect(lightBg).toBe('rgb(244, 241, 251)');
      expect(lightBg).not.toBe(lightDocBg);
      expect(lightBg).not.toBe(darkBg);
      const lightKw = await panel.locator('.doc-scenario-kw').first().evaluate(el => getComputedStyle(el).color);
      expect(lightKw).toBe('rgb(156, 47, 128)');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('scenario step text is escaped — a <script> in a step cannot inject markup (security)', async ({ page }) => {
    const id = `t-gk-xss-${Date.now()}`;
    try {
      makeTicket(id, [
        '# Acceptance', '', '## Criteria', '- [ ] **x**', '```gherkin',
        'Scenario: xss', '  Given <script>window.__gkxss=true</script>', '  Then ok', '```',
        '', '## Test Plan', '- [x] run', '', '## QA', '- [x] Tested locally', '',
      ].join('\n'));
      await openAcceptance(page, id);
      await expect(page.locator('#m-body .doc-scenario')).toBeVisible();
      expect(await page.evaluate(() => window.__gkxss)).toBeUndefined();
      await expect(page.locator('#m-body .doc-scenario')).toContainText('<script>window.__gkxss=true</script>');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('toolbar Scenario button inserts a checkbox + ```gherkin skeleton (C1)', async ({ page }) => {
    const id = `t-gk-insert-${Date.now()}`;
    try {
      makeTicket(id, DISCOUNT_ACCEPTANCE);
      await openAcceptance(page, id);
      await page.locator('#btn-edit-doc').click();
      await expect(page.locator('#m-edit-area')).toBeVisible();
      await expect(page.locator('#m-edit-area')).toHaveValue(/Valid code above minimum/);

      // The former "Code block" (toggle) button is gone; a Scenario button exists.
      await expect(page.locator('.editor-tool[data-insert="toggle"]')).toHaveCount(0);
      const scenarioBtn = page.locator('#m-editor-toolbar .editor-tool[data-insert="scenario"]');
      await expect(scenarioBtn).toBeVisible();

      // Insert at the start of the textarea.
      await page.locator('#m-edit-area').focus();
      await page.locator('#m-edit-area').evaluate(el => { el.setSelectionRange(0, 0); });
      await scenarioBtn.click();

      const val = await page.locator('#m-edit-area').inputValue();
      expect(val).toContain('```gherkin');
      expect(val).toContain('Scenario: Scenario name');
      expect(val).toMatch(/- \[ \] \*\*Scenario name\*\*/);
      expect(val).toContain('Given ');
      expect(val).toContain('When ');
      expect(val).toContain('Then ');
      expect(val).not.toContain('<details>');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a malformed ```gherkin block blocks save; a well-formed one saves (C5)', async ({ page }) => {
    const id = `t-gk-valid-${Date.now()}`;
    try {
      makeTicket(id, DISCOUNT_ACCEPTANCE);
      await openAcceptance(page, id);
      await page.locator('#btn-edit-doc').click();
      await expect(page.locator('#m-edit-area')).toBeVisible();
      // enterEditMode fetches the doc content asynchronously and overwrites the
      // textarea once it resolves — wait for the real content before editing, or
      // a fill() lands before the fetch wipes it (t-c58c pattern).
      await expect(page.locator('#m-edit-area')).toHaveValue(/Valid code above minimum/);

      // Each of the four validateGherkinBlocks branches must block the save with a
      // specific message (runtime coverage of every branch, in the real board).
      // Accept dialogs in the handler so the alert unblocks the page (a
      // waitForEvent+click Promise.all deadlocks: click can't resolve while the
      // alert blocks the page, and the dialog isn't accepted until after).
      const dialogs = [];
      page.on('dialog', d => { dialogs.push(d.message()); d.accept(); });
      const mk = (block) => ['# Acceptance', `Ticket: \`${id}\``, '', '## Criteria',
        '- [ ] **bad**', ...block, '', '## Test Plan', '- [x] run', '', '## QA',
        '- [x] Tested locally', ''].join('\n');
      // An unclosed fence consumes everything after it, so a trailing section would
      // trip a different branch — put its required headings BEFORE the Criteria block
      // so the unclosed ```gherkin genuinely runs to EOF.
      const unclosedDoc = ['# Acceptance', `Ticket: \`${id}\``, '', '## Test Plan',
        '- [x] run', '', '## QA', '- [x] Tested locally', '', '## Criteria',
        '- [ ] **bad**', '```gherkin', 'Scenario: x', '  Given a'].join('\n');
      const badCases = [
        { doc: mk(['```gherkin', 'Given cart_total 10', 'Scenario: x', '  Then ok', '```']), re: /before any Scenario/ },
        { doc: mk(['```gherkin', 'Scenario: empty', 'Scenario: real', '  Given a', '```']), re: /no Given\/When\/Then/ },
        { doc: mk(['```gherkin', 'Scenario: x', '  Given a', '  Wen b', '```']), re: /Unrecognized Gherkin keyword/ },
        { doc: unclosedDoc, re: /Unclosed/ },
      ];
      for (const c of badCases) {
        const n = dialogs.length;
        await page.locator('#m-edit-area').fill(c.doc);
        await page.locator('#btn-save-top').click();
        await expect.poll(() => dialogs.slice(n).join('\n')).toMatch(c.re);
        await expect(page.locator('#m-edit-area')).toBeVisible(); // save was blocked
      }

      // Well-formed (the discount fixture) — save succeeds, no new dialog.
      const dialogCountAfterMalformed = dialogs.length;
      await page.locator('#m-edit-area').fill(DISCOUNT_ACCEPTANCE.replace('# Acceptance\n', `# Acceptance\nTicket: \`${id}\`\n`));
      await page.locator('#btn-save-top').click();
      await expect(page.locator('#m-edit-area')).toBeHidden();
      expect(dialogs.length).toBe(dialogCountAfterMalformed);
      await expect(page.locator('#m-body .doc-scenario')).toBeVisible();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });
});

test.describe('ticket-scoped feature reference (t-f89a)', () => {
  const DISCOUNT_FEATURE = [
    'Scenario: Valid code above minimum applies the discount',
    '  Given cart_total 120.00',
    '  When discount is applied',
    '  Then applied is true',
    '',
    'Scenario: Valid code below minimum is rejected',
    '  Given cart_total 40.00',
    '  When discount is applied',
    '  Then applied is false',
    '',
    'Scenario: Unknown code is rejected',
    '  Given cart_total 200.00',
    '  When discount is applied',
    '  Then applied is false',
    '',
  ].join('\n');

  function makeRefTicket(id, refPath, { withFile = true, runner = null } = {}) {
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ticket.md'), [
      '---', `id: ${id}`, 'status: in_progress', 'type: feature', 'priority: 2',
      'created: 2026-07-27T00:00:00Z', '---', '', '# Feature ref test', '',
    ].join('\n'));
    const fenceLines = runner ? [refPath, `runner: ${runner}`] : [refPath];
    fs.writeFileSync(path.join(dir, 'acceptance.md'), [
      '# Acceptance', `Ticket: \`${id}\``, '', '## Criteria',
      '- [ ] **Discount rules (from file)**', '```gherkin-file', ...fenceLines, '```', '',
      '## Test Plan', '- [x] run', '', '## QA', '- [x] Tested locally', '',
    ].join('\n'));
    if (withFile) {
      fs.mkdirSync(path.join(dir, 'features'), { recursive: true });
      fs.writeFileSync(path.join(dir, 'features', 'discount.feature'), DISCOUNT_FEATURE);
    }
  }

  async function openAcceptance(page, id) {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"]`).click();
    await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
    await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
    await expect(page.locator('.doc-tab.active')).toHaveText('Acceptance');
  }

  test('a ```gherkin-file reference renders the ticket-local .feature as a scenario panel (A3)', async ({ page }) => {
    const id = `t-fr-ok-${Date.now()}`.slice(0, 24);
    const tid = `t-fr${Math.random().toString(36).slice(2, 4)}`;
    try {
      makeRefTicket(tid, 'features/discount.feature');
      await openAcceptance(page, tid);
      const panel = page.locator('#m-body .doc-scenario').first();
      // Hydration is async — wait for the fetched panel to replace the placeholder.
      await expect(panel.locator('.doc-scenario-kw', { hasText: /^Scenario$/ })).toHaveCount(3, { timeout: 5000 });
      await expect(page.locator('#m-body')).not.toContainText('```gherkin-file');
      await expect(page.locator('#m-body')).not.toContainText('Could not load');
      await expect(page.locator('#m-body .doc-scenario-error')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', tid), { recursive: true, force: true });
    }
  });

  test('a ```gherkin-file block with a runner: line renders a non-executable resolved-command label (t-6f8e)', async ({ page }) => {
    const tid = `t-fn${Math.random().toString(36).slice(2, 4)}`;
    try {
      makeRefTicket(tid, 'features/discount.feature', { runner: 'python dsl_runner.py' });
      await openAcceptance(page, tid);
      const panel = page.locator('#m-body .doc-scenario').first();
      await expect(panel.locator('.doc-scenario-kw', { hasText: /^Scenario$/ })).toHaveCount(3, { timeout: 5000 });
      // The runner label appears beneath the panel, showing `<runner> <feature-path>`.
      const runnerLabel = page.locator('#m-body .doc-scenario-runner');
      await expect(runnerLabel).toHaveCount(1);
      await expect(runnerLabel).toContainText('python dsl_runner.py features/discount.feature');
      // `runner:` must not leak as literal fence text, and no error state.
      await expect(page.locator('#m-body')).not.toContainText('```gherkin-file');
      await expect(page.locator('#m-body')).not.toContainText('runner: python');
      await expect(page.locator('#m-body .doc-scenario-error')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', tid), { recursive: true, force: true });
    }
  });

  test('a path-only ```gherkin-file block renders no runner label (t-6f8e backward-compat)', async ({ page }) => {
    const tid = `t-fp${Math.random().toString(36).slice(2, 4)}`;
    try {
      makeRefTicket(tid, 'features/discount.feature');
      await openAcceptance(page, tid);
      const panel = page.locator('#m-body .doc-scenario').first();
      await expect(panel.locator('.doc-scenario-kw', { hasText: /^Scenario$/ })).toHaveCount(3, { timeout: 5000 });
      await expect(page.locator('#m-body .doc-scenario-runner')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', tid), { recursive: true, force: true });
    }
  });

  test('a reference to a missing .feature shows a legible error state, not a blank panel (A3/A4)', async ({ page }) => {
    const tid = `t-fx${Math.random().toString(36).slice(2, 4)}`;
    try {
      makeRefTicket(tid, 'features/missing.feature', { withFile: false });
      await openAcceptance(page, tid);
      const err = page.locator('#m-body .doc-scenario-error');
      await expect(err).toBeVisible({ timeout: 5000 });
      await expect(err).toContainText('Could not load features/missing.feature');
      // Distinct, legible background in dark and light.
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
      const darkBg = await err.evaluate(el => getComputedStyle(el).backgroundColor);
      expect(darkBg).toBe('rgb(25, 26, 39)');
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
      const lightBg = await err.evaluate(el => getComputedStyle(el).backgroundColor);
      expect(lightBg).toBe('rgb(244, 241, 251)');
      expect(lightBg).not.toBe(darkBg);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', tid), { recursive: true, force: true });
    }
  });

  test('an invalid (traversal) reference path renders an inline invalid-reference state, never fetches escape (A2)', async ({ page }) => {
    const tid = `t-fv${Math.random().toString(36).slice(2, 4)}`;
    try {
      makeRefTicket(tid, 'features/../../secret.feature', { withFile: false });
      await openAcceptance(page, tid);
      const err = page.locator('#m-body .doc-scenario-error');
      await expect(err).toBeVisible({ timeout: 5000 });
      await expect(err).toContainText('Invalid feature reference');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', tid), { recursive: true, force: true });
    }
  });

  test('toolbar "Scenario from file" button inserts a ```gherkin-file skeleton (A5)', async ({ page }) => {
    const tid = `t-ft${Math.random().toString(36).slice(2, 4)}`;
    try {
      makeRefTicket(tid, 'features/discount.feature');
      await openAcceptance(page, tid);
      await page.locator('#btn-edit-doc').click();
      await expect(page.locator('#m-edit-area')).toBeVisible();
      await expect(page.locator('#m-edit-area')).toHaveValue(/gherkin-file/);
      const btn = page.locator('#m-editor-toolbar .editor-tool[data-insert="scenario-file"]');
      await expect(btn).toBeVisible();
      await page.locator('#m-edit-area').focus();
      await page.locator('#m-edit-area').evaluate(el => { el.setSelectionRange(0, 0); });
      await btn.click();
      const val = await page.locator('#m-edit-area').inputValue();
      expect(val).toContain('```gherkin-file');
      expect(val).toContain('features/name.feature');
      expect(val).toContain('runner: python dsl_runner.py');
      expect(val).toMatch(/- \[ \] \*\*Scenario name\*\*/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', tid), { recursive: true, force: true });
    }
  });
});

test.describe('cockpit in board (t-ddc8)', () => {
  // Stub /api/cockpit so no real daemon is ever spawned — these tests exercise
  // the board's mode switch + rail + inline acceptance, not the PTY.
  async function stubCockpit(page) {
    await page.route('**/api/cockpit', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:1', launched: true }),
    }));
  }

  function writeTicket(id, status, { acceptanceCriteria = null, plan = null, ci = false, demo = false, worktreePreference = '' } = {}) {
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ticket.md'), [
      '---', `id: ${id}`, `status: ${status}`, 'type: feature', 'priority: 2',
      `ci: ${ci}`, `demo: ${demo}`,
      ...(worktreePreference ? [`worktree_preference: ${worktreePreference}`] : []),
      'created: 2026-08-24T00:00:00Z', '---', '', `# Cockpit test ${id}`, '',
    ].join('\n'));
    if (acceptanceCriteria) {
      fs.writeFileSync(path.join(dir, 'acceptance.md'), [
        '# Acceptance', `Ticket: \`${id}\``, '', '## Criteria',
        ...acceptanceCriteria, '', '## Test Plan', '- [ ] a check', '', '## QA', '- [ ] Tested locally', '',
      ].join('\n'));
    }
    if (plan) fs.writeFileSync(path.join(dir, 'plan.md'), plan.join('\n'));
  }

  test('Cockpit sessions panel lists sessions across projects; clicking a row opens that session (t-391a)', async ({ page }) => {
    const idA = `t-cspan-${Date.now()}`;
    try {
      writeTicket(idA, 'in_progress', {
        acceptanceCriteria: ['- [ ] a criterion'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/cockpit-sessions', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { session: 's1', ticket: idA, project_root: '/Users/me/projA', cwd: '/Users/me/projA', agent: 'claude', status: 'running', started: '2026-09-10T00:00:00Z' },
          { session: 's2', ticket: 't-othr', project_root: 'C:\\Users\\me\\projB', cwd: 'C:\\Users\\me\\projB', agent: 'pi', status: 'needs-you', started: '2026-09-10T00:00:00Z' },
        ]),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      const panel = page.locator('#cockpit-sessions');
      await expect(panel).toBeVisible();
      await expect(panel.locator('.cockpit-session-row')).toHaveCount(2);
      await expect(panel).toContainText(idA);
      // t-7ea8: the row shows the full project directory path, not just the basename.
      await expect(panel).toContainText('/Users/me/projA');
      await expect(panel).toContainText('projA');
      // Windows project path renders too (full path incl. basename).
      await expect(panel).toContainText('projB');
      await expect(panel.locator('.cs-status.needs-you')).toHaveText('needs-you');

      // Clicking the row opens that session in the cockpit overlay (attach — the
      // tokened Kill/Save & End live there; no token-free board kill, t-ddc8).
      await panel.locator(`.cockpit-session-row[data-ticket="${idA}"]`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', idA), { recursive: true, force: true });
    }
  });

  test('collapse toggle is top-anchored + STATUS shows HANDOFF Next Steps (t-6ecc)', async ({ page }) => {
    const id = `t-6ecc-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] a criterion'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/handoff', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ raw: `# Handoff\n## Current Focus\n${id} — build it\n\n## Next Steps\n1. Run \`sprint complete\` to close ${id}.\n` }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // (1) the rail collapse toggle sits near the TOP of the rail (not vertically centered).
      const toggle = page.locator('#ck-rail-toggle');
      await expect(toggle).toBeVisible();
      const tb = await toggle.boundingBox();
      const rail = await page.locator('.ck-rail').boundingBox();
      expect(tb.y - rail.y).toBeLessThan(40);
      // and it still toggles rail-collapsed
      await toggle.click();
      await expect(page.locator('#cockpit')).toHaveClass(/rail-collapsed/);
      await toggle.click();
      await expect(page.locator('#cockpit')).not.toHaveClass(/rail-collapsed/);

      // (2) STATUS surfaces the HANDOFF ## Next Steps (Status accordion is open by default).
      await expect(page.locator('#ck-state')).toContainText('Next steps');
      await expect(page.locator('#ck-state')).toContainText('sprint complete');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Resume on an in-progress card enters cockpit mode; acceptance renders; Esc returns', async ({ page }) => {
    const id = `t-ckres-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] First cockpit criterion'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low | Gate model: haiku', '', '- [x] Plan approved', '', '## Approach', 'Filled.', ''],
      });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);

      const resumeBtn = page.locator(`.card[data-id="${id}"] .card-start`);
      await expect(resumeBtn).toHaveText('▶ Resume');
      await resumeBtn.click();

      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      // Acceptance starts collapsed — expand it to see the checklist.
      await page.locator('.ck-accordion-header[data-accordion="ck-accept-section"]').click();
      // Inline acceptance rail renders the Criteria checklist.
      await expect(page.locator('#ck-accept .doc-bullet').first()).toBeVisible();
      await expect(page.locator('#ck-accept')).toContainText('First cockpit criterion');
      // Read-only model chip inherits from plan.md's Gate model.
      await expect(page.locator('#ck-model')).toContainText('haiku');
      // The embedded terminal iframe points at the (stubbed) daemon /cockpit with embed=1.
      await expect(page.locator('#ck-iframe')).toHaveAttribute('src', /\/cockpit\?ticket=.*embed=1/);

      await page.keyboard.press('Escape');
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a worktree that can\'t see .tickets shows a warning bubble and mounts no terminal, legible in dark and light (t-e5ff)', async ({ page }) => {
    const id = `t-ckwt-${Date.now()}`;
    const blockedCwd = '/tmp/wt-e5ff/feat-x';
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'] });
      await stubCockpit(page);
      // Stub the worktree list: main visible, the feat worktree not (tickets_visible:false).
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true },
          { path: blockedCwd, branch: 'feat/x', is_main: false, tickets_visible: false },
        ]),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      const startBtn = page.locator(`.card[data-id="${id}"] .card-start`);
      await expect(startBtn).toHaveText('▶ Start');
      await startBtn.click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // The WORKTREE accordion is expanded by default; the bubble renders after
      // /api/worktrees resolves — wait for it. It is present because a
      // tickets_visible:false worktree exists.
      const warn = page.locator('.ck-worktree-warn');
      await expect(warn).toBeVisible();
      await expect(warn).toContainText('.tickets/ is gitignored');

      // Selecting the blocked worktree must NOT mount the terminal iframe (so no
      // Start-sprint button is ever presented for it).
      await page.locator(`.ck-worktree-row[data-cwd="${blockedCwd}"]`).click();
      await expect(page.locator('#ck-iframe')).toHaveCSS('visibility', 'hidden');
      await expect(page.locator('#ck-term-msg')).toContainText('gitignored');

      // Legible in both themes: distinct, non-transparent tinted background.
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
      const darkBg = await warn.evaluate(el => getComputedStyle(el).backgroundColor);
      await page.screenshot({ path: '/tmp/e5ff-dark.png' });
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
      const lightBg = await warn.evaluate(el => getComputedStyle(el).backgroundColor);
      await page.screenshot({ path: '/tmp/e5ff-light.png' });
      expect(lightBg).toBe('rgb(254, 226, 226)'); // #fee2e2, the light-mode block tint
      expect(darkBg).not.toBe(lightBg);
      expect(darkBg).not.toBe('rgba(0, 0, 0, 0)'); // not transparent in dark
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('after Start, "Working in:" reflects the daemon-resolved cwd and warns on a wrong-tree mismatch (t-7590)', async ({ page }) => {
    const id = `t-ckcwd-${Date.now()}`;
    const wtPath = '/tmp/wt-7590/verify2';
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: wtPath, branch: 'verify2', is_main: false, tickets_visible: true, ticket_present: true },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator(`.ck-worktree-row[data-cwd="${wtPath}"]`)).toBeVisible();

      // User selected the verify2 worktree AND the daemon reports it actually
      // spawned there → label shows verify2, no mismatch warning.
      await page.evaluate((wt) => { cockpitState.worktreeCwd = wt; applyActualWorkingCwd(wt); }, wtPath);
      await expect(page.locator('#ck-worktree-note')).toContainText('Working in:');
      await expect(page.locator('#ck-worktree-note')).toContainText('verify2');
      await expect(page.locator('#ck-worktree-note .ck-worktree-warn')).toHaveCount(0);

      // verify2 still selected, but the daemon reports it actually spawned in
      // MAIN (the wrong-tree bug) → loud warning naming the real cwd.
      await page.evaluate((root) => { applyActualWorkingCwd(root); }, PROJECT_ROOT);
      const warn = page.locator('#ck-worktree-note .ck-worktree-warn');
      await expect(warn).toBeVisible();
      await expect(warn).toContainText(PROJECT_ROOT);
      await expect(warn).toContainText('not the worktree you selected');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a newly-created worktree row auto-selects even when create-response and list paths differ in format (t-3e58)', async ({ page }) => {
    const id = `t-ck3e58-${Date.now()}`;
    // The daemon materializes Windows-style backslash paths in the POST create
    // response, while `git worktree list` (GET) reports forward slashes — same
    // dir, different format. Reproduced here on any OS to exercise the string
    // mismatch that made the new row fail to auto-highlight.
    const createPath = 'C:\\Users\\me\\p-worktrees\\feat-3e58';   // POST /api/worktrees response
    const listPath = 'C:/Users/me/p-worktrees/feat-3e58';         // GET /api/worktrees rendered data-cwd
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'] });
      await stubCockpit(page);
      let created = false;
      await page.route('**/api/worktrees**', route => {
        if (route.request().method() === 'POST') {
          created = true;
          return route.fulfill({
            status: 200, contentType: 'application/json',
            body: JSON.stringify({ ok: true, path: createPath, branch: 'feat/3e58' }),
          });
        }
        const entries = [{ path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true }];
        if (created) entries.push({ path: listPath, branch: 'feat/3e58', is_main: false, tickets_visible: true, ticket_present: true });
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(entries) });
      });
      // create() confirms twice (a window.confirm to create); auto-accept.
      page.on('dialog', d => d.accept());
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await page.locator('#ck-worktree-new-input').fill('feat/3e58');
      await page.locator('.ck-worktree-new-plus').click();

      // The new row (rendered with the forward-slash data-cwd) must auto-select
      // despite the backslash create-response path — the whole point of t-3e58.
      const newRow = page.locator(`.ck-worktree-row[data-cwd="${listPath}"]`);
      await expect(newRow).toHaveClass(/selected/);
      // and nothing else is left selected
      await expect(page.locator('.ck-worktree-row.selected')).toHaveCount(1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a fresh OPEN cockpit selects no worktree row until one is picked (t-470d)', async ({ page }) => {
    const id = `t-ck470d-${Date.now()}`;
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'] });
      await stubCockpit(page);
      // Main + one other worktree, both able to see the ticket. The point of the
      // test is the SELECTION state, not visibility gating.
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: '/tmp/wt-470d/feat', branch: 'feat/470d', is_main: false, tickets_visible: true, ticket_present: true },
        ]),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // The worktree rows have rendered (Main + feat).
      await expect(page.locator('.ck-worktree-row')).toHaveCount(2);
      // t-470d: on a fresh OPEN start (cockpitState.worktreeCwd === null, nothing
      // picked yet) NO row is selected — the Main row must not falsely highlight.
      // The terminal is correspondingly gated ("Select a worktree above").
      await expect(page.locator('.ck-worktree-row.selected')).toHaveCount(0);
      await expect(page.locator('#ck-iframe')).toHaveCSS('visibility', 'hidden');
      await expect(page.locator('#ck-term-msg')).toContainText('Select a worktree above');

      // After the user clicks the Main checkout row (data-cwd=""), it — and only
      // it — becomes selected.
      await page.locator('.ck-worktree-row[data-cwd=""]').click();
      await expect(page.locator('.ck-worktree-row[data-cwd=""]')).toHaveClass(/selected/);
      await expect(page.locator('.ck-worktree-row.selected')).toHaveCount(1);
      // …and the null-gate is released: the terminal-mount path runs, so the
      // "Select a worktree above" message is gone (worktreeCwd is now '').
      await expect(page.locator('#ck-term-msg')).not.toContainText('Select a worktree above');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  // --- t-19d1 (+ t-d218): Start must never deadlock, and Main is preselected when there's no real choice ---
  const onlyMain = route => route.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify([{ path: PROJECT_ROOT, branch: 'master', is_main: true, tickets_visible: true, ticket_present: true }]) });
  const mainAndFeat = route => route.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify([
      { path: PROJECT_ROOT, branch: 'master', is_main: true, tickets_visible: true, ticket_present: true },
      { path: '/tmp/wt-19d1/feat', branch: 'sprint/feat-19d1', is_main: false, tickets_visible: true, ticket_present: true },
    ]) });
  async function openFromCard(page, id) {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"] .card-start`).click();
    await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
  }

  test('a git repo with no commits yet shows the WORKTREE rail and Start is not stuck (t-d218)', async ({ page }) => {
    const id = `t-ckd218-${Date.now()}`;
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'] });
      await stubCockpit(page);
      await page.route('**/api/git', route => route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ branch: 'master', project: 'fresh', root: PROJECT_ROOT, modified: 3, log: [], total_commits: null, is_git: true }) }));
      await page.route('**/api/worktrees**', onlyMain);
      await openFromCard(page, id);
      await expect(page.locator('#ck-worktree-section')).toBeVisible();
      await expect(page.locator('.ck-worktree-row[data-cwd=""]')).toHaveClass(/selected/);   // only Main exists -> preselected
      await expect(page.locator('#ck-term-msg')).not.toContainText('Select a worktree above');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a non-git project has no WORKTREE section and the terminal is not gated (t-d218)', async ({ page }) => {
    const id = `t-ckngit-${Date.now()}`;
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'] });
      await stubCockpit(page);
      await page.route('**/api/git', route => route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ branch: '', project: 'nogit', modified: 0, log: [], is_git: false }) }));
      await openFromCard(page, id);
      await expect(page.locator('#ck-worktree-section')).toBeHidden();
      await expect(page.locator('#ck-term-msg')).not.toContainText('Select a worktree above');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('New Ticket in a no-commits repo shows the Worktree row, and the default Main checkout saves main-checkout (t-d218, t-19d1)', async ({ page }) => {
    await page.route('**/api/git', route => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ branch: 'master', project: 'fresh', root: PROJECT_ROOT, modified: 0, log: [], total_commits: null, is_git: true }) }));
    await page.route('**/api/worktrees**', onlyMain);
    const title = `Main default ${Date.now()}`;
    let createdId = '';
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await expect(page.locator('#c-worktree-row')).toBeVisible();
      await expect(page.locator('#c-worktree-pills .create-pill[data-wt="main"]')).toHaveClass(/active/);
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();
      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      expect(fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md'), 'utf8')).toContain('worktree_preference: main-checkout');
      await expect(card.locator('.card-wt-pref')).toHaveText('Worktree: Main checkout');
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('New Ticket\'s Main checkout choice (main-checkout) shows on the card and preselects Main even with other worktrees (t-19d1)', async ({ page }) => {
    const id = `t-ckmain-${Date.now()}`;
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], worktreePreference: 'main-checkout' });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', mainAndFeat);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await expect(page.locator(`.card[data-id="${id}"] .card-wt-pref`)).toHaveText('Worktree: Main checkout');
      await page.locator(`.card[data-id="${id}"]`).click();
      const meta = page.locator('#m-meta .meta-item', { hasText: 'Worktree' });
      await expect(meta).toContainText('Main checkout');
      await expect(meta).not.toContainText('main-checkout');
      await expect(meta).not.toContainText('created when you start');
      await page.keyboard.press('Escape');
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('.ck-worktree-row[data-cwd=""]')).toHaveClass(/selected/);
      await expect(page.locator('.ck-worktree-row.selected')).toHaveCount(1);
      await expect(page.locator('#ck-term-msg')).not.toContainText('Select a worktree above');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('an open ticket in progress in a worktree sits in IN PROGRESS with Resume and a worktree chip, and Resume preselects that worktree (t-19d1)', async ({ page }) => {
    const id = `t-ckwtrun-${Date.now()}`;
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'] });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', mainAndFeat);
      await page.route('**/api/tickets**', async route => {
        const resp = await route.fetch();
        const json = await resp.json();
        for (const t of json) if (t.id === id) t.branch_divergence = { branch: 'sprint/feat-19d1', status: 'in_progress', where: 'worktree', merged: false };
        await route.fulfill({ response: resp, json });
      });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      const card = page.locator(`.column-body[data-status="in_progress"] .card[data-id="${id}"]`);
      await expect(card).toBeVisible();
      await expect(page.locator(`.column-body[data-status="open"] .card[data-id="${id}"]`)).toHaveCount(0);
      await expect(card.locator('.card-start')).toHaveText('▶ Resume');
      await expect(card.locator('.card-wt-run')).toHaveText('Worktree: sprint/feat-19d1');
      await expect(card.locator('.card-diverge')).toHaveCount(0);
      for (const theme of ['dark', 'light']) {
        await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
        await card.screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-19d1', 'visuals', `card-wt-run-${theme}.png`) });
      }
      // Modal prev/next walk the card's lane (IN PROGRESS), not main's raw `open` status.
      writeTicket(`${id}-ip`, 'in_progress');
      await page.reload();
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await card.click();
      const onlyInProgress = await page.locator('#btn-ticket-prev').isDisabled() ? '#btn-ticket-next' : '#btn-ticket-prev';
      await page.locator(onlyInProgress).click();
      const landed = (await page.locator('#m-id').textContent()).trim();
      expect(landed).not.toBe(id);
      expect(fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', landed, 'ticket.md'), 'utf8')).toMatch(/^status: in_progress$/m);
      await page.keyboard.press('Escape');
      await card.locator('.card-start').click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('.ck-worktree-row[data-cwd="/tmp/wt-19d1/feat"]')).toHaveClass(/selected/);
      // Display only: main's ticket.md still says open.
      expect(fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', id, 'ticket.md'), 'utf8')).toContain('status: open');
    } finally {
      for (const t of [id, `${id}-ip`]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', t), { recursive: true, force: true });
    }
  });

  test('card age: a full ISO created reads "just now"; a legacy date-only created reads in days, never hours (t-19d1)', async ({ page }) => {
    const iso = `t-ckageI-${Date.now()}`, dateOnly = `t-ckageD-${Date.now()}`;
    try {
      writeTicket(iso, 'open'); writeTicket(dateOnly, 'open');
      const today = new Date(); const ymd = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
      await page.route('**/api/tickets**', async route => {
        const resp = await route.fetch();
        const json = await resp.json();
        for (const t of json) {
          if (t.id === iso) t.created = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
          if (t.id === dateOnly) t.created = ymd;
        }
        await route.fulfill({ response: resp, json });
      });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill('t-ckage');
      await expect(page.locator(`.card[data-id="${iso}"] .card-footer`)).toContainText('just now');
      await expect(page.locator(`.card[data-id="${dateOnly}"] .card-footer`)).toContainText('today');
      await expect(page.locator(`.card[data-id="${dateOnly}"] .card-footer`)).not.toContainText(/\dh ago/);
    } finally {
      for (const t of [iso, dateOnly]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', t), { recursive: true, force: true });
    }
  });

  test('Cockpit sessions rows show where each session runs: Main checkout or the worktree folder (t-19d1)', async ({ page }) => {
    await page.route('**/api/cockpit-sessions', route => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify([
        { ticket: 't-aaaa', project_root: 'C:\\Users\\u\\Documents\\ToDo', cwd: 'C:\\Users\\u\\Documents\\ToDo', agent: 'claude', status: 'running' },
        { ticket: 't-bbbb', project_root: 'C:\\Users\\u\\Documents\\ToDo', cwd: 'C:\\Users\\u\\Documents\\ToDo-worktrees\\sprint-update-ui-styling', agent: 'claude', status: 'running' },
      ]) }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    const rows = page.locator('#cockpit-sessions .cockpit-session-row');
    await expect(rows).toHaveCount(2);
    await expect(rows.nth(0).locator('.cs-where')).toHaveText('Main checkout');
    await expect(rows.nth(1).locator('.cs-where')).toHaveText('sprint-update-ui-styling');
    await expect(rows.nth(1)).toHaveAttribute('title', 'C:\\Users\\u\\Documents\\ToDo-worktrees\\sprint-update-ui-styling');
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      await page.locator('#cockpit-sessions').screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-19d1', 'visuals', `sessions-${theme}.png`) });
    }
  });

  test('a session cwd holding a quote cannot break out of the row title attribute (t-19d1)', async ({ page }) => {
    const hostile = '/tmp/a"onmouseover="window.__pwned=1"x';
    await page.route('**/api/cockpit-sessions', route => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify([{ ticket: 't-cccc"x="1', project_root: '/tmp/p', cwd: hostile, agent: 'claude', status: 'running' }]) }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    const row = page.locator('#cockpit-sessions .cockpit-session-row');
    await expect(row).toHaveCount(1);
    await expect(row).toHaveAttribute('title', hostile);
    expect(await row.getAttribute('onmouseover')).toBeNull();
    expect(await row.getAttribute('x')).toBeNull();
    await row.hover();
    expect(await page.evaluate(() => window.__pwned)).toBeUndefined();
  });

  test('a locked in_progress ticket selects the Main row and shows its friendly label even when the persisted lock path differs only in slash format (t-f15b, Windows)', async ({ page }) => {
    const id = `t-ckf15b-${Date.now()}`;
    // Simulate the daemon's native-OS-separator lock path (Windows backslashes)
    // for the SAME directory /api/worktrees reports with forward slashes — the
    // exact mismatch a raw === comparison misses (t-f15b). No existing test
    // caught this because every prior fixture used an identical string for
    // both sides.
    const winStyleLock = PROJECT_ROOT.replace(/\//g, '\\');
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: true, cwd: winStyleLock, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // The Main row must render selected despite the slash-format mismatch.
      await expect(page.locator('.ck-worktree-row[data-cwd=""]')).toHaveClass(/selected/);
      await expect(page.locator('.ck-worktree-row.selected')).toHaveCount(1);

      // The Status rail resolves the friendly label, not the raw backslash path.
      await expect(page.locator('#ck-state')).toContainText('Running in: Main checkout (current)');
      await expect(page.locator('#ck-state')).not.toContainText(winStyleLock);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a symlinked cwd does not raise a false "Working in" mismatch warning, but a genuine wrong-tree still does (t-eed3)', async ({ page }) => {
    const id = `t-cksym-${Date.now()}`;
    const selWt = '/tmp/wt-eed3/x';               // board's selected worktree (unresolved, e.g. macOS /tmp)
    const resolvedWt = '/private/tmp/wt-eed3/x';   // daemon EvalSymlinks'd actual + requested (same real dir)
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: selWt, branch: 'x', is_main: false, tickets_visible: true, ticket_present: true },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator(`.ck-worktree-row[data-cwd="${selWt}"]`)).toBeVisible();

      // Symlink case: the board selected /tmp/x; the daemon reports it spawned in
      // /private/tmp/x AND echoes the resolved requested /private/tmp/x. Same real
      // dir → actual matches `requested` → NO mismatch warning (t-eed3).
      await page.evaluate(({ sel, resolved }) => {
        cockpitState.worktreeCwd = sel;
        applyActualWorkingCwd(resolved, resolved);
      }, { sel: selWt, resolved: resolvedWt });
      await expect(page.locator('#ck-worktree-note')).toContainText('Working in:');
      await expect(page.locator('#ck-worktree-note .ck-worktree-warn')).toHaveCount(0);

      // Genuine wrong-tree: the board selected /tmp/x (requested /tmp/x) but the
      // daemon spawned in MAIN → actual differs from both selected and requested
      // → the t-7590 warning still fires.
      await page.evaluate(({ root, sel }) => {
        cockpitState.worktreeCwd = sel;
        applyActualWorkingCwd(root, sel);
      }, { root: PROJECT_ROOT, sel: selWt });
      await expect(page.locator('#ck-worktree-note .ck-worktree-warn')).toBeVisible();
      await expect(page.locator('#ck-worktree-note .ck-worktree-warn')).toContainText('not the worktree you selected');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('cockpit ticket context is not duplicated: rail card is canonical; topbar shows it only when the rail is collapsed (t-4272)', async ({ page }) => {
    const id = `t-ckdedup-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // Rail expanded (default): the rail card carries id/status/title; the
      // duplicate topbar copy is hidden.
      await expect(page.locator('#ck-tc-id')).toBeVisible();
      await expect(page.locator('#ck-tc-status')).toBeVisible();
      await expect(page.locator('#ck-id')).toBeHidden();
      await expect(page.locator('#ck-status')).toBeHidden();
      await expect(page.locator('#ck-title')).toBeHidden();

      // Collapse the rail: the topbar context becomes the visible fallback so
      // ticket context is never lost.
      await page.locator('#ck-rail-toggle').click();
      await expect(page.locator('#cockpit')).toHaveClass(/rail-collapsed/);
      await expect(page.locator('#ck-id')).toBeVisible();
      await expect(page.locator('#ck-status')).toBeVisible();
      await expect(page.locator('#ck-title')).toBeVisible();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('cockpit rail shows the WORKTREE plan/acceptance when the session runs in a worktree (t-1357)', async ({ page }) => {
    const id = `t-ckwd-${Date.now()}`;
    const wtPath = '/tmp/wt-1357/sprint-x';
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] MAIN-checkout criterion'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'MAIN approach body', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: wtPath, branch: 'sprint-x', is_main: false, tickets_visible: true, ticket_present: true },
        ]),
      }));
      // Locked to the worktree → the rail's effective cwd is the worktree.
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: true, cwd: wtPath, main_dirty: false }),
      }));
      // The worktree's docs differ from main's — the rail must show THESE.
      await page.route('**/api/cockpit-docs/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({
          plan: '# Plan\n\n## Approach\nWORKTREE-ONLY approach body',
          acceptance: '# Acceptance\n\n## Criteria\n- [ ] worktree-only criterion\n\n## Test Plan\n- [ ] wt test',
          handoff: '## Current Focus\nWORKTREE focus line.',
        }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await page.locator('.ck-accordion-header[data-accordion="ck-plan-section"]').click();
      await expect(page.locator('#ck-plan')).toContainText('WORKTREE-ONLY approach body');
      await expect(page.locator('#ck-plan')).not.toContainText('MAIN approach body');

      await page.locator('.ck-accordion-header[data-accordion="ck-accept-section"]').click();
      await expect(page.locator('#ck-accept')).toContainText('worktree-only criterion');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('the Unlock button and confirm name the locked worktree branch (t-816e)', async ({ page }) => {
    const id = `t-ckul816-${Date.now()}`;
    const lockedCwd = '/tmp/wt-816e/feat-unlockme';
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      // The locked worktree IS in the list (branch feat/unlockme) → the label
      // resolves to the branch, not a bare path/basename.
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: lockedCwd, branch: 'feat/unlockme', is_main: false, tickets_visible: true, ticket_present: true },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: true, cwd: lockedCwd, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // The button names the locked worktree branch.
      const unlockBtn = page.locator('#ck-worktree-unlock');
      await expect(unlockBtn).toBeVisible();
      await expect(unlockBtn).toContainText('feat/unlockme');

      // The confirm dialog names the branch too, and keeps the t-fe3c phrases.
      let msg = '';
      page.once('dialog', d => { msg = d.message(); d.dismiss(); });
      await unlockBtn.click();
      expect(msg).toContain('feat/unlockme');
      expect(msg).toContain('locked to');
      expect(msg).toContain('fresh session');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a locked ticket shows an Unlock button; cancel keeps the lock, confirm clears it and re-renders (t-fe3c)', async ({ page }) => {
    const id = `t-ckul-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      let unlocked = false;
      let unlockPosts = 0;
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([{ path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true }]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify(unlocked
          ? { locked: false, cwd: null, main_dirty: false }
          : { locked: true, cwd: '/tmp/wt-fe3c/feat-x', main_dirty: false }),
      }));
      await page.route('**/api/worktree-unlock/**', route => {
        unlockPosts++; unlocked = true;
        route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, unlocked: true }) });
      });

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // Locked ticket → Unlock button present.
      const unlockBtn = page.locator('#ck-worktree-unlock');
      await expect(unlockBtn).toBeVisible();
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
      await page.screenshot({ path: '/tmp/fe3c-dark.png' });
      await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
      await page.screenshot({ path: '/tmp/fe3c-light.png' });

      // Cancel the confirm → no request, button stays, lock intact.
      page.once('dialog', d => d.dismiss());
      await unlockBtn.click();
      expect(unlockPosts).toBe(0);
      await expect(page.locator('#ck-worktree-unlock')).toBeVisible();

      // Confirm → the dialog explains (names the locked dir), posts unlock, and
      // the re-render (lock now false) removes the button.
      page.once('dialog', d => { expect(d.message()).toContain('locked to'); expect(d.message()).toContain('fresh session'); d.accept(); });
      await page.locator('#ck-worktree-unlock').click();
      await expect(page.locator('#ck-worktree-unlock')).toHaveCount(0);
      expect(unlockPosts).toBe(1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('while locked, picking a different worktree is blocked and directs to Unlock (t-9203)', async ({ page }) => {
    const id = `t-ck92-${Date.now()}`;
    const lockedCwd = '/tmp/wt-9203/feat-x';
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      // Two worktrees: the main checkout and the feat-x worktree the ticket is locked to.
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true },
          { path: lockedCwd, branch: 'feat-x', is_main: false, tickets_visible: true },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: true, cwd: lockedCwd, main_dirty: false }),
      }));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('#ck-worktree-unlock')).toBeVisible(); // locked → Unlock present

      // Clicking the Main row (data-cwd="") while locked must be BLOCKED with an
      // alert directing to Unlock — not silently switch (the wrong-tree danger).
      // The alert fires after an async lock fetch, so wait for the dialog event.
      const dialogPromise = page.waitForEvent('dialog');
      await page.locator('.ck-worktree-row[data-cwd=""]').click();
      const dialog = await dialogPromise;
      expect(dialog.message()).toContain('Unlock worktree');
      await dialog.accept();
      // The Main row must NOT become the selection — the effective cwd stays the lock.
      await expect(page.locator('.ck-worktree-row[data-cwd=""]')).not.toHaveClass(/selected/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a ticket locked to a worktree that lacks it mounts no terminal even with Main selected; unlock + pick Main mounts it (t-2a1c)', async ({ page }) => {
    const id = `t-ckep-${Date.now()}`;
    // The user's exact scenario: .tickets/ un-ignored but uncommitted, so the
    // worktree is check-ignore "visible" (tickets_visible:true) yet physically
    // lacks .tickets/<id> (ticket_present:false); the ticket is locked to it.
    const lockedCwd = '/tmp/wt-2a1c/test-1';
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      let unlocked = false;
      // Ticket-scoped worktree list: main present, the locked worktree NOT
      // present (but check-ignore visible — the divergence this ticket fixes).
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: lockedCwd, branch: 'test-1', is_main: false, tickets_visible: true, ticket_present: false },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify(unlocked
          ? { locked: false, cwd: null, main_dirty: false }
          : { locked: true, cwd: lockedCwd, main_dirty: false }),
      }));
      await page.route('**/api/worktree-unlock/**', route => {
        unlocked = true;
        route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, unlocked: true }) });
      });

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // Locked to a worktree that can't see the ticket → no terminal mounts
      // (so no Start button), with a lock-aware, actionable message — even
      // though check-ignore would call the worktree "visible".
      await expect(page.locator('#ck-iframe')).toHaveCSS('visibility', 'hidden');
      await expect(page.locator('#ck-term-msg')).toContainText("locked to a worktree that doesn't contain it");
      await expect(page.locator('#ck-worktree-unlock')).toBeVisible();

      // Unlock → re-render clears the lock; nothing is selected yet.
      page.once('dialog', d => d.accept());
      await page.locator('#ck-worktree-unlock').click();
      await expect(page.locator('#ck-worktree-unlock')).toHaveCount(0);
      await expect(page.locator('#ck-iframe')).toHaveCSS('visibility', 'hidden');

      // Pick the Main checkout (row cwd="") → effective cwd is present → mounts.
      await page.locator('.ck-worktree-row[data-cwd=""]').click();
      await expect(page.locator('#ck-iframe')).toHaveAttribute('src', /\/cockpit\?ticket=.*embed=1/);
      await expect(page.locator('#ck-iframe')).toHaveCSS('visibility', 'visible');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('New Ticket modal Worktree row: +New sets worktree_preference on the created ticket (t-644a)', async ({ page }) => {
    await page.route('**/api/worktrees**', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify([{ path: PROJECT_ROOT, branch: 'main', is_main: true }]),
    }));
    const title = `Worktree pref test ${Date.now()}`;
    let createdId = '';
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await expect(page.locator('#c-worktree-row')).toBeVisible();
      await page.locator('#c-worktree-pills .create-pill[data-wt="new"]').click();
      await page.locator('#c-wt-new-input').fill('sprint/feat-644a');
      await page.locator('#c-title').fill(title);
      await page.locator('#c-submit').click();
      const card = page.locator('.card', { hasText: title });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      const raw = fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md'), 'utf8');
      expect(raw).toContain('worktree_preference: sprint/feat-644a');
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('New Ticket modal Worktree +New: suggests a branch name from the title, stops once edited directly', async ({ page }) => {
    await page.route('**/api/worktrees**', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify([{ path: PROJECT_ROOT, branch: 'main', is_main: true }]),
    }));
    let createdId = '';
    try {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#btn-create').click();
      await page.waitForSelector('#create-modal', { timeout: 3000 });
      await page.locator('#c-worktree-pills .create-pill[data-wt="new"]').click();
      await expect(page.locator('#c-wt-new-input')).toHaveValue('');

      await page.locator('#c-title').fill('Fix login bug on Safari');
      await expect(page.locator('#c-wt-new-input')).toHaveValue('sprint/fix-login-bug-on-safari', { timeout: 1000 });

      // Editing the field directly stops further auto-updates from the title.
      await page.locator('#c-wt-new-input').fill('sprint/my-custom-name');
      await page.locator('#c-title').fill('Fix login bug on Safari and Chrome');
      await page.waitForTimeout(450);
      await expect(page.locator('#c-wt-new-input')).toHaveValue('sprint/my-custom-name');

      await page.locator('#c-submit').click();
      const card = page.locator('.card', { hasText: 'Fix login bug on Safari and Chrome' });
      await expect(card).toBeVisible();
      createdId = await card.getAttribute('data-id') || '';
      const raw = fs.readFileSync(path.join(PROJECT_ROOT, '.tickets', createdId, 'ticket.md'), 'utf8');
      expect(raw).toContain('worktree_preference: sprint/my-custom-name');
    } finally {
      if (createdId) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', createdId), { recursive: true, force: true });
    }
  });

  test('rail pre-fill: worktree_preference matching an existing worktree pre-selects its radio (t-644a)', async ({ page }) => {
    const id = `t-wtpre-${Date.now()}`;
    const wtPath = '/tmp/wt-644a/feat-x';
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
        worktreePreference: 'feat-x',
      });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: wtPath, branch: 'feat-x', is_main: false, tickets_visible: true, ticket_present: true },
        ]),
      }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      // No .cockpit-cwd binding yet (worktree-lock reports unlocked) → the row
      // matching worktree_preference pre-selects, not Main.
      await expect(page.locator(`.ck-worktree-row[data-cwd="${wtPath}"]`)).toHaveClass(/selected/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  const OPEN_PLAN = ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''];

  test('worktree preference (t-15ee): open card chip + modal item only when a choice was made; hostile names stay inert', async ({ page }) => {
    const stamp = Date.now();
    const withId = `t-wtp-a-${stamp}`, noneId = `t-wtp-b-${stamp}`, progId = `t-wtp-c-${stamp}`, evilId = `t-wtp-d-${stamp}`;
    const evil = '<img src=x onerror=1> a" onmouseover="window.__pwn=1';
    try {
      writeTicket(withId, 'open', { worktreePreference: 'sprint/wt-15ee' });
      writeTicket(noneId, 'open');
      writeTicket(progId, 'in_progress', { worktreePreference: 'sprint/wt-progress' });
      writeTicket(evilId, 'open', { worktreePreference: evil });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(withId);
      const card = page.locator(`.card[data-id="${withId}"]`);
      await expect(card.locator('.card-wt-pref')).toHaveText('Worktree: sprint/wt-15ee');
      await expect(card.locator('.card-wt-pref')).toHaveAttribute('title', /created when you start the sprint/);
      await card.click();
      const item = page.locator('#m-meta .meta-item', { hasText: 'Worktree' });
      await expect(item).toContainText('sprint/wt-15ee');
      await expect(item).toContainText('created when you start');
      await page.keyboard.press('Escape');

      await page.locator('#board-search').fill(noneId);
      await expect(page.locator(`.card[data-id="${noneId}"] .card-wt-pref`)).toHaveCount(0);
      await page.locator(`.card[data-id="${noneId}"]`).click();
      await expect(page.locator('#m-meta .meta-item', { hasText: 'Worktree' })).toHaveCount(0);
      await page.keyboard.press('Escape');

      await page.locator('#board-search').fill(progId);
      await expect(page.locator(`.card[data-id="${progId}"] .card-wt-pref`)).toHaveCount(0);
      await page.locator(`.card[data-id="${progId}"]`).click();
      await expect(page.locator('#m-meta .meta-item', { hasText: 'Worktree' })).toHaveCount(0); // open-only
      await page.keyboard.press('Escape');

      await page.locator('#board-search').fill(evilId);
      const evilCard = page.locator(`.card[data-id="${evilId}"]`);
      await expect(evilCard.locator('.card-wt-pref')).toContainText('<img src=x onerror=1>');
      await expect(evilCard.locator('.card-wt-pref img')).toHaveCount(0);
      const evilChip = evilCard.locator('.card-wt-pref');
      expect(await evilChip.getAttribute('onmouseover')).toBeNull();
      expect(await evilChip.getAttribute('title')).toContain('onmouseover="window.__pwn=1"');
      await evilCard.click();
      await expect(page.locator('#m-meta .meta-item', { hasText: 'Worktree' }).locator('img')).toHaveCount(0);
      expect(await page.evaluate(() => window.__pwn)).toBeUndefined();
    } finally {
      for (const id of [withId, noneId, progId, evilId]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  async function openRailFor(page, id, posts) {
    await stubCockpit(page);
    await page.route('**/api/worktrees**', route => {
      if (route.request().method() === 'POST') {
        posts.push(route.request().postData());
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, path: '/tmp/wt-15ee/created' }) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([
        { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
      ]) });
    });
    await page.route('**/api/worktree-lock/**', route => route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"] .card-start`).click();
    await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
  }

  test('worktree preference (t-15ee): rail arms "+ New" for an explicit choice, names it, and still needs the confirm', async ({ page }) => {
    const id = `t-wtp-r-${Date.now()}`;
    const posts = [];
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN, worktreePreference: 'sprint/wt-15ee' });
      await openRailFor(page, id, posts);
      await expect(page.locator('#ck-worktree-new-input')).toHaveValue('sprint/wt-15ee');
      await expect(page.locator('.ck-worktree-new-plus')).toBeEnabled();
      await expect(page.locator('#ck-worktree .ck-add-hint')).toContainText('You chose sprint/wt-15ee when creating this ticket');
      await expect(page.locator('#ck-term-msg')).toContainText('You chose "sprint/wt-15ee" when creating this ticket');

      // Dismissing the confirm creates nothing.
      let dialogText = '';
      page.once('dialog', d => { dialogText = d.message(); d.dismiss(); });
      await page.locator('.ck-worktree-new-plus').click();
      await expect.poll(() => dialogText).toContain('Create a new git worktree for branch "sprint/wt-15ee"');
      expect(posts).toHaveLength(0);

      // Accepting it creates exactly that worktree.
      page.once('dialog', d => d.accept());
      await page.locator('.ck-worktree-new-plus').click();
      await expect.poll(() => posts.length).toBe(1);
      expect(JSON.parse(posts[0])).toEqual({ branch: 'sprint/wt-15ee' });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('worktree preference (t-15ee): edge cases — existing worktree, main branch, unlocked in_progress, hostile name in the rail', async ({ page }) => {
    const stamp = Date.now();
    const existId = `t-wtp-e-${stamp}`, mainId = `t-wtp-m-${stamp}`, progId = `t-wtp-p-${stamp}`, evilId = `t-wtp-h-${stamp}`;
    const evil = '<img src=x onerror=1> a" b';
    const posts = [];
    const wtPath = '/tmp/wt-15ee/existing';
    const openRail = async id => {
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
    };
    try {
      writeTicket(existId, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN, worktreePreference: 'sprint/already-there' });
      writeTicket(mainId, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN, worktreePreference: 'main' });
      writeTicket(progId, 'in_progress', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN, worktreePreference: 'sprint/prog-15ee' });
      writeTicket(evilId, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN, worktreePreference: evil });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => route.request().method() === 'POST'
        ? (posts.push(route.request().postData()), route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, path: '/tmp/x' }) }))
        : route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([
            { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
            { path: wtPath, branch: 'sprint/already-there', is_main: false, tickets_visible: true, ticket_present: true },
          ]) }));
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json', body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));

      // Preference names a worktree that already exists: its row is pre-selected, "+ New" is NOT armed
      // for it — the field keeps the default suggestion (creatable since t-29cc, still behind a confirm).
      await openRail(existId);
      await expect(page.locator(`.ck-worktree-row[data-cwd="${wtPath}"]`)).toHaveClass(/selected/);
      await expect(page.locator('#ck-worktree-new-input')).toHaveValue(`sprint/${existId}`);
      await expect(page.locator('#ck-worktree .ck-add-hint')).not.toContainText('You chose');

      // Preference equals the main checkout's own branch: nothing to create, so not armed.
      await openRail(mainId);
      await expect(page.locator('.ck-worktree-new-plus')).toBeDisabled();
      await expect(page.locator('#ck-term-msg')).not.toContainText('You chose');

      // Unlocked in_progress ticket (board-flipped, nothing bound yet) behaves like open: armed.
      await openRail(progId);
      await expect(page.locator('.ck-worktree-new-plus')).toBeEnabled();
      await expect(page.locator('#ck-worktree .ck-add-hint')).toContainText('You chose sprint/prog-15ee');

      // Hostile name: inert text in the hint (element) and the gate message (textContent).
      await openRail(evilId);
      await expect(page.locator('#ck-worktree .ck-add-hint')).toContainText('<img src=x onerror=1>');
      await expect(page.locator('#ck-worktree .ck-add-hint img')).toHaveCount(0);
      await expect(page.locator('#ck-term-msg')).toContainText('<img src=x onerror=1>');
      await expect(page.locator('#ck-term-msg img')).toHaveCount(0);
      expect(posts).toHaveLength(0);
    } finally {
      for (const id of [existId, mainId, progId, evilId]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('+ New creates the untouched default suggestion after a confirm, by click or Enter (t-29cc)', async ({ page }) => {
    const id = `t-wtp-n-${Date.now()}`;
    const posts = [];
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN });
      await openRailFor(page, id, posts);
      const input = page.locator('#ck-worktree-new-input');
      const plus = page.locator('.ck-worktree-new-plus');
      await expect(input).toHaveValue(`sprint/${id}`);
      await expect(plus).toBeEnabled();
      await expect(page.locator('#ck-worktree .ck-add-hint')).toContainText('Click + New (or press Enter) to create this worktree');
      await expect(page.locator('#ck-term-msg')).not.toContainText('You chose');
      for (const theme of ['dark', 'light']) {
        await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
        await page.locator('#ck-worktree').screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-29cc', 'visuals', `worktree-new-${theme}.png`) });
      }

      // Dismissing the confirm creates nothing.
      let dialogText = '';
      page.once('dialog', d => { dialogText = d.message(); d.dismiss(); });
      await plus.click();
      await expect.poll(() => dialogText).toContain(`Create a new git worktree for branch "sprint/${id}"`);
      expect(posts).toHaveLength(0);

      // Enter follows the same rule as the click: confirm, then exactly one POST.
      page.once('dialog', d => d.accept());
      await input.press('Enter');
      await expect.poll(() => posts.length).toBe(1);
      expect(JSON.parse(posts[0])).toEqual({ branch: `sprint/${id}` });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('+ New stays disabled for the main branch and an existing worktree, for click and Enter alike (t-29cc)', async ({ page }) => {
    const id = `t-wtp-x-${Date.now()}`;
    const posts = [];
    let dialogs = 0;
    page.on('dialog', d => { dialogs++; d.dismiss(); });
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN, worktreePreference: 'main' });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', route => {
        if (route.request().method() === 'POST') {
          posts.push(route.request().postData());
          return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, path: '/tmp/x' }) });
        }
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
          { path: '/tmp/wt-29cc/taken', branch: 'sprint/taken', is_main: false, tickets_visible: true, ticket_present: true },
        ]) });
      });
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json', body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      const input = page.locator('#ck-worktree-new-input');
      const plus = page.locator('.ck-worktree-new-plus');
      // A `main` preference pre-fills the main checkout's own branch: never creatable.
      await expect(input).toHaveValue('main');
      await expect(plus).toBeDisabled();
      await input.press('Enter');
      // An existing worktree's branch: disabled, and Enter stops at an alert, not a POST.
      await input.fill('sprint/taken');
      await expect(plus).toBeDisabled();
      await input.press('Enter');
      // Too short.
      await input.fill('abc');
      await expect(plus).toBeDisabled();
      await input.press('Enter');
      await page.waitForTimeout(300);
      expect(posts).toHaveLength(0);
      expect(dialogs).toBe(1); // only the existing-branch alert; no create confirm ever opened
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  // t-d254: rail with a stubbed /api/ticket-commit plan; `log` records every
  // POST in order as "<route>:<body>" so tests can assert commit-then-create.
  async function openRailWithPlan(page, id, plan, log, { commitReply } = {}) {
    await stubCockpit(page);
    await page.route('**/api/worktrees**', route => {
      if (route.request().method() === 'POST') {
        log.push('worktrees:' + route.request().postData());
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, path: '/tmp/wt-d254/created' }) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([
        { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
      ]) });
    });
    await page.route('**/api/worktree-lock/**', route => route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
    }));
    await page.route('**/api/ticket-commit/**', route => {
      if (route.request().method() === 'POST') {
        log.push('commit:' + route.request().postData());
        const reply = commitReply || { status: 200, body: { ok: true, commit: 'abc1234', committed: [], message: plan.message } };
        return route.fulfill({ status: reply.status, contentType: 'application/json', body: JSON.stringify(reply.body) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(plan) });
    });
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"] .card-start`).click();
    await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
  }
  const d254Plan = (id, over = {}) => ({
    required: [`.tickets/${id}/a"b <img src=x onerror="window.__pwn=1">.md`, `.tickets/${id}/ticket.md`],
    recommended: ['.tickets/.gitignore'],
    optional: [`.tickets/${id}/cockpit-sessions.md`],
    other_dirty: ['.claude/settings.json', 'src/app.py'],
    other_dirty_count: 3,
    message: `chore: add ticket ${id}`,
    blocked: '',
    ...over,
  });

  test('uncommitted ticket: rail warns, + New opens the grouped commit dialog, Commit & create commits then creates (t-d254)', async ({ page }) => {
    const id = `t-wtp-c-${Date.now()}`;
    const log = [];
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN });
      const plan = d254Plan(id);
      await openRailWithPlan(page, id, plan, log);
      await expect(page.locator('#ck-worktree-uncommitted')).toContainText(`${id} isn't committed yet`);

      await page.locator('.ck-worktree-new-plus').click();
      const dlg = page.locator('#ck-tcommit');
      await expect(dlg).toHaveClass(/open/);
      const cb = p => dlg.locator(`input[data-path="${p.replace(/"/g, '\\"')}"]`);
      for (const p of plan.required) { await expect(cb(p)).toBeChecked(); await expect(cb(p)).toBeDisabled(); }
      await expect(cb('.tickets/.gitignore')).toBeChecked();
      await expect(cb('.tickets/.gitignore')).toBeEnabled();
      await expect(cb(`.tickets/${id}/cockpit-sessions.md`)).not.toBeChecked();
      // Other dirty files are listed without a checkbox, with the overflow count.
      await expect(dlg.locator('.ck-tcm-file.muted')).toHaveCount(2);
      await expect(dlg.locator('.ck-tcm-file.muted input')).toHaveCount(0);
      await expect(dlg).toContainText('(+1 more)');
      await expect(dlg.locator('#ck-tcm-msg')).toContainText(`chore: add ticket ${id}`);
      await expect(dlg.locator('#ck-tcm-intro')).toContainText(`Commit it on the main checkout first, then create the "sprint/${id}" worktree.`);
      // The hostile file name is text, not markup.
      await expect(dlg.locator('img')).toHaveCount(0);
      await expect(dlg).toContainText('<img src=x onerror=');
      expect(await page.evaluate(() => window.__pwn)).toBeUndefined();
      for (const theme of ['dark', 'light']) {
        await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
        await dlg.locator('.ck-leave-confirm').screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-d254', 'visuals', `commit-dialog-${theme}.png`) });
      }

      await dlg.locator('#ck-tcm-commit').click();
      await expect.poll(() => log.length).toBe(2);
      expect(log[0].startsWith('commit:')).toBe(true);
      expect(JSON.parse(log[0].slice('commit:'.length)).paths.sort()).toEqual([...plan.required, '.tickets/.gitignore'].sort());
      expect(log[1]).toBe('worktrees:' + JSON.stringify({ branch: `sprint/${id}` }));
      await expect(dlg).not.toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('commit dialog: Cancel, a failed commit, and no create-without-committing escape (t-d254)', async ({ page }) => {
    const id = `t-wtp-k-${Date.now()}`;
    const log = [];
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN });
      await openRailWithPlan(page, id, d254Plan(id), log, { commitReply: { status: 500, body: { ok: false, error: 'pre-commit hook failed: lint' } } });
      const dlg = page.locator('#ck-tcommit');
      const plus = page.locator('.ck-worktree-new-plus');

      // Cancel: nothing sent, dialog closes.
      await plus.click();
      await expect(dlg).toHaveClass(/open/);
      await dlg.locator('#ck-tcm-cancel').click();
      await expect(dlg).not.toHaveClass(/open/);
      expect(log).toHaveLength(0);

      // A failed commit keeps the dialog open with the server's reason and creates nothing.
      await plus.click();
      await dlg.locator('#ck-tcm-commit').click();
      await expect(dlg.locator('#ck-tcm-status')).toContainText('pre-commit hook failed: lint');
      await expect(dlg).toHaveClass(/open/);
      expect(log.filter(l => l.startsWith('worktrees:'))).toHaveLength(0);

      // No "Create without committing": that worktree couldn't see the ticket. Only
      // Commit & create and Cancel exist, and Cancel after a failure creates nothing.
      await expect(dlg.locator('button')).toHaveText(['Commit & create worktree', 'Cancel']);
      await dlg.locator('#ck-tcm-cancel').click();
      await expect(dlg).not.toHaveClass(/open/);
      expect(log.filter(l => l.startsWith('worktrees:'))).toHaveLength(0);
      expect(log.filter(l => l.startsWith('commit:'))).toHaveLength(1); // only the failed attempt
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('slow repo: Commit & create and + New show a spinner while each step runs (t-d254)', async ({ page }) => {
    const id = `t-wtp-s-${Date.now()}`;
    let releaseCommit, releaseWorktree;
    const commitGate = new Promise(r => { releaseCommit = r; });
    const worktreeGate = new Promise(r => { releaseWorktree = r; });
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN });
      await stubCockpit(page);
      await page.route('**/api/worktrees**', async route => {
        if (route.request().method() === 'POST') {
          await worktreeGate;
          return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, path: '/tmp/wt-d254/slow' }) });
        }
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true, tickets_visible: true, ticket_present: true },
        ]) });
      });
      await page.route('**/api/worktree-lock/**', route => route.fulfill({
        status: 200, contentType: 'application/json', body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));
      await page.route('**/api/ticket-commit/**', async route => {
        if (route.request().method() === 'POST') {
          await commitGate;
          return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, commit: 'abc1234', committed: [], message: 'm' }) });
        }
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(d254Plan(id)) });
      });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      const plus = page.locator('.ck-worktree-new-plus');
      await plus.click();
      const commitBtn = page.locator('#ck-tcm-commit');
      await commitBtn.click();
      // Commit in flight: spinner + label, busy, Cancel locked.
      await expect(commitBtn).toHaveText('Committing…');
      await expect(commitBtn.locator('.ck-spin')).toBeVisible();
      await expect(commitBtn).toHaveAttribute('aria-busy', 'true');
      await expect(page.locator('#ck-tcm-cancel')).toBeDisabled();
      releaseCommit();
      // Worktree creation in flight: the dialog is gone, + New carries the spinner.
      await expect(page.locator('#ck-tcommit')).not.toHaveClass(/open/);
      await expect(plus).toHaveText('Creating…');
      await expect(plus.locator('.ck-spin')).toBeVisible();
      await expect(plus).toHaveAttribute('aria-busy', 'true');
      await expect(commitBtn).toHaveText('Commit & create worktree'); // label restored for next time
      releaseWorktree();
      await expect(page.locator('.ck-worktree-new-plus')).toHaveText('+ New');
    } finally {
      releaseCommit(); releaseWorktree();
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('in a Cockpit project tab, ticket-commit GET and POST both carry ?project= (t-d254)', async ({ page }) => {
    // Live-caught on the VM: unscoped, the plan came back "not a git repository"
    // (the board's default folder), and a POST would have committed there.
    const seen = [];
    await page.route('**/api/ticket-commit/**', route => {
      seen.push(route.request().method() + ' ' + route.request().url());
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' }); // never reaches a real repo
    });
    await page.goto(BASE + '/?project=zz9');
    await page.evaluate(async () => {
      await fetch('/api/ticket-commit/t-abcd').catch(() => {});
      await fetch('/api/ticket-commit/t-abcd', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"paths":[]}' }).catch(() => {});
    });
    await expect.poll(() => seen.length).toBe(2);
    expect(seen[0]).toMatch(/^GET .*\/api\/ticket-commit\/t-abcd\?project=zz9$/);
    expect(seen[1]).toMatch(/^POST .*\/api\/ticket-commit\/t-abcd\?project=zz9$/);
  });

  test('only optional files uncommitted: no warning, + New keeps the plain confirm (t-d254)', async ({ page }) => {
    const id = `t-wtp-o-${Date.now()}`;
    const log = [];
    try {
      writeTicket(id, 'open', { acceptanceCriteria: ['- [ ] c'], plan: OPEN_PLAN });
      await openRailWithPlan(page, id, d254Plan(id, { required: [], recommended: [], message: '' }), log);
      await expect(page.locator('.ck-worktree-new-plus')).toBeEnabled();
      await expect(page.locator('#ck-worktree-uncommitted')).toHaveCount(0);
      let dialogText = '';
      page.once('dialog', d => { dialogText = d.message(); d.dismiss(); });
      await page.locator('.ck-worktree-new-plus').click();
      await expect.poll(() => dialogText).toContain('Create a new git worktree for branch');
      await expect(page.locator('#ck-tcommit')).not.toHaveClass(/open/);
      expect(log).toHaveLength(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('IN PROGRESS card shows a read-only worktree chip when bound; empty when unbound (t-644a)', async ({ page }) => {
    const boundId = `t-wtchip-a-${Date.now()}`;
    const unboundId = `t-wtchip-b-${Date.now()}`;
    const wtPath = '/tmp/wt-644a/chip-x';
    try {
      writeTicket(boundId, 'in_progress');
      writeTicket(unboundId, 'in_progress');
      await page.route('**/api/worktrees**', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify([
          { path: PROJECT_ROOT, branch: 'main', is_main: true },
          { path: wtPath, branch: 'chip-x', is_main: false },
        ]),
      }));
      await page.route(`**/api/worktree-lock/${boundId}`, route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: true, cwd: wtPath, main_dirty: false }),
      }));
      await page.route(`**/api/worktree-lock/${unboundId}`, route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ locked: false, cwd: null, main_dirty: false }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await expect(page.locator(`.card[data-id="${boundId}"] .card-wt-chip`)).toHaveText('chip-x');
      await expect(page.locator(`.card[data-id="${unboundId}"] .card-wt-chip`)).toHaveText('');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', boundId), { recursive: true, force: true });
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', unboundId), { recursive: true, force: true });
    }
  });

  test('non-git project hides the New Ticket Worktree row; it reappears once git becomes available (t-644a)', async ({ page }) => {
    let gitBody = { branch: '', project: 'nogit', modified: 0, log: [] }; // no total_commits -> non-git
    await page.route('**/api/git', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify(gitBody),
    }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    await page.locator('#btn-create').click();
    await page.waitForSelector('#create-modal', { timeout: 3000 });
    await expect(page.locator('#c-worktree-row')).toBeHidden();
    await page.locator('#c-cancel').click();
    await expect(page.locator('#create-overlay')).not.toHaveClass(/open/);

    // Live re-check, not cached at registration: flip the mocked /api/git
    // response and re-run the same poll loadData() already runs on a timer.
    gitBody = { branch: 'main', project: 'nogit', root: PROJECT_ROOT, modified: 0, log: [], total_commits: 5 };
    await page.evaluate(() => loadData());
    await page.waitForTimeout(100);
    await page.locator('#btn-create').click();
    await page.waitForSelector('#create-modal', { timeout: 3000 });
    await expect(page.locator('#c-worktree-row')).toBeVisible();
  });

  test('non-git project hides the rail worktree accordion and the board chip (t-644a)', async ({ page }) => {
    const id = `t-wtnogit-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', {
        acceptanceCriteria: ['- [ ] c'],
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low', '', '- [x] Plan approved', '', '## Approach', 'x', ''],
      });
      await stubCockpit(page);
      await page.route('**/api/git', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ branch: '', project: 'nogit', modified: 0, log: [] }), // no total_commits
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await expect(page.locator(`.card[data-id="${id}"] .card-wt-chip`)).toHaveText('');

      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('#ck-worktree-section')).toBeHidden();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('card affordance is status-gated: Start on open, Resume on in-progress, none on closed', async ({ page }) => {
    const stamp = Date.now();
    const openId = `t-ckopen-${stamp}`;
    const progId = `t-ckprog-${stamp}`;
    const doneId = `t-ckdone-${stamp}`;
    try {
      writeTicket(openId, 'open');
      writeTicket(progId, 'in_progress');
      writeTicket(doneId, 'closed');
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(openId);
      await expect(page.locator(`.card[data-id="${openId}"] .card-start`)).toHaveText('▶ Start');

      await page.locator('#board-search').fill(progId);
      await expect(page.locator(`.card[data-id="${progId}"] .card-start`)).toHaveText('▶ Resume');

      await page.locator('#board-search').fill(doneId);
      await expect(page.locator(`.card[data-id="${doneId}"] .card-start`)).toHaveCount(0);
    } finally {
      for (const id of [openId, progId, doneId]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Start stays visible on a card that is both ci:true and demo:true (card-head has no slack for a 6th badge)', async ({ page }) => {
    const id = `t-ckoverf-${Date.now()}`;
    try {
      writeTicket(id, 'open', { ci: true, demo: true });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);

      const card = page.locator(`.card[data-id="${id}"]`);
      const startBtn = card.locator('.card-start');
      await expect(startBtn).toHaveText('▶ Start');
      await expect(startBtn).toBeVisible();
      // Floated into .card-body (not squeezed as a 6th .card-head flex child), so its
      // box must stay within the card's own bounding box, not clipped past card-head's
      // overflow:hidden edge.
      const cardBox = await card.boundingBox();
      const btnBox = await startBtn.boundingBox();
      expect(btnBox.x + btnBox.width).toBeLessThanOrEqual(cardBox.x + cardBox.width + 1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('per-worktree tickets (t-644a/t-01a4): Start on an open card stays enabled while another ticket is in progress', async ({ page }) => {
    const stamp = Date.now();
    const openId = `t-ck1open-${stamp}`;
    const progId = `t-ck1prog-${stamp}`;
    try {
      writeTicket(openId, 'open');
      writeTicket(progId, 'in_progress');
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(openId);
      // The one-active-ticket gate is now scoped per worktree on the backend
      // (t-01a4), not repo-wide — the client must never pre-disable Start just
      // because another ticket is in_progress; a real per-worktree conflict
      // (if any) surfaces from the actual Start attempt's own response.
      const startBtn = page.locator(`.card[data-id="${openId}"] .card-start`);
      await expect(startBtn).toBeEnabled();
      await expect(startBtn).not.toHaveClass(/disabled/);
    } finally {
      for (const id of [openId, progId]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Acceptance renders view-only in the cockpit — clicking a bullet never writes to acceptance.md (t-96a8)', async ({ page }) => {
    const id = `t-cktog-${Date.now()}`;
    const acc = path.join(PROJECT_ROOT, '.tickets', id, 'acceptance.md');
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] Do not toggle me'] });
      const before = fs.readFileSync(acc, 'utf8');
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.locator('.ck-accordion-header[data-accordion="ck-accept-section"]').click();

      const bullet = page.locator('#ck-accept .doc-bullet', { hasText: 'Do not toggle me' });
      await expect(bullet).toBeVisible();
      await expect(bullet).not.toHaveAttribute('data-check-idx');
      await bullet.click();
      await page.waitForTimeout(300); // no write path exists — nothing to poll for

      expect(fs.readFileSync(acc, 'utf8')).toBe(before);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('focus toggle collapses the ticket rail to maximize the terminal', async ({ page }) => {
    const id = `t-ckfocus-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] Something'] });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await expect(page.locator('#cockpit')).not.toHaveClass(/rail-collapsed/);
      await page.locator('#ck-rail-toggle').click();
      await expect(page.locator('#cockpit')).toHaveClass(/rail-collapsed/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('rail is drag-resizable, and collapse still reaches 44px after a manual resize', async ({ page }) => {
    const id = `t-ckresize-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] Something'] });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      const rail = page.locator('.ck-rail');
      const before = (await rail.boundingBox()).width;
      const handle = page.locator('#ck-rail-resize');
      const hb = await handle.boundingBox();
      await page.mouse.move(hb.x + hb.width / 2, hb.y + hb.height / 2);
      await page.mouse.down();
      await page.mouse.move(hb.x + hb.width / 2 + 80, hb.y + hb.height / 2);
      await page.mouse.up();
      const after = (await rail.boundingBox()).width;
      expect(after).toBeGreaterThan(before + 60);

      // An inline width from the resize must not defeat the 44px collapse
      // rule — inline styles otherwise always beat a class selector. Poll
      // (toHaveCSS retries) rather than read boundingBox once immediately —
      // the width change animates over .ck-rail's own transition, so an
      // instant snapshot right after the click can still show the pre-click
      // value for a moment.
      await page.locator('#ck-rail-toggle').click();
      await expect(rail).toHaveCSS('width', '44px');

      // Expanding again restores the manually-resized width, not the default.
      await page.locator('#ck-rail-toggle').click();
      await expect(async () => {
        expect((await rail.boundingBox()).width).toBeGreaterThan(before + 60);
      }).toPass({ timeout: 2000 });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('findHandoffStateForTicket extracts only the matching ticket\'s bullet, including continuation lines', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    const raw = [
      '## In Progress',
      '',
      '- **`t-aaaa`** (Other ticket) — some unrelated state that should never match.',
      '  Continuation line for the other ticket.',
      '- **`t-bbbb`** (Our ticket) — plan approved, implementation done: built the thing.',
      '  Next: user confirms, then sprint complete.',
      '- **`t-cccc`** (A third ticket) — also unrelated.',
      '',
      '## Discoveries',
      '- something that must never leak into the In Progress extraction',
    ].join('\n');
    const result = await page.evaluate((raw) => findHandoffStateForTicket(raw, 't-bbbb'), raw);
    expect(result).toContain('Our ticket');
    expect(result).toContain('Next: user confirms');
    expect(result).not.toContain('t-aaaa');
    expect(result).not.toContain('t-cccc');
    expect(result).not.toContain('Discoveries');

    const none = await page.evaluate((raw) => findHandoffStateForTicket(raw, 't-zzzz'), raw);
    expect(none).toBeNull();
  });

  test('Status section renders this ticket\'s HANDOFF.md bullet, above Acceptance', async ({ page }) => {
    const id = `t-ckstate-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] a criterion'] });
      await stubCockpit(page);
      await page.route('**/api/handoff', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ focus: null, raw: `## In Progress\n\n- **\`${id}\`** (Test) — plan approved, doing the thing.\n` }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await expect(page.locator('#ck-state')).toContainText('plan approved, doing the thing');
      // Status sits above Acceptance in DOM order, and starts expanded
      // (not collapsed like Acceptance/Test Plan) — it's the freshest,
      // most immediately relevant context.
      const sectionOrder = await page.locator('.ck-accordion-section').evaluateAll(els => els.map(e => e.id));
      expect(sectionOrder.indexOf('ck-state-section')).toBeLessThan(sectionOrder.indexOf('ck-accept-section'));
      await expect(page.locator('#ck-state-section')).not.toHaveClass(/collapsed/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Status section shows a hint when this ticket has no HANDOFF.md bullet', async ({ page }) => {
    const id = `t-cknostate-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await stubCockpit(page);
      await page.route('**/api/handoff', route => route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify({ focus: null, raw: '## In Progress\n\n- Nothing about this ticket here.\n' }),
      }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await expect(page.locator('#ck-state')).toContainText('No saved state yet');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Test Plan panel renders view-only, distinct from Criteria — clicking it never writes to acceptance.md (t-96a8)', async ({ page }) => {
    const id = `t-cktp-${Date.now()}`;
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    try {
      writeTicket(id, 'in_progress');
      const accPath = path.join(dir, 'acceptance.md');
      const before = [
        '# Acceptance', `Ticket: \`${id}\``, '', '## Criteria',
        '- [x] Crit one', '- [ ] Crit two', '',
        '## Test Plan', '- [ ] Plan one', '- [x] Plan two', '',
        '## QA', '- [ ] Tested locally', '',
      ].join('\n');
      fs.writeFileSync(accPath, before);
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // Both sections start collapsed — expand Test Plan to see it.
      await page.locator('.ck-accordion-header[data-accordion="ck-testplan-section"]').click();
      await expect(page.locator('#ck-testplan')).toBeVisible();
      await expect(page.locator('#ck-testplan')).toContainText('Plan one');
      await expect(page.locator('#ck-testplan')).toContainText('Plan two');
      await expect(page.locator('#ck-testplan')).not.toContainText('Crit one');

      const bullet = page.locator('#ck-testplan .doc-bullet', { hasText: 'Plan one' });
      await expect(bullet).not.toHaveAttribute('data-check-idx');
      await bullet.click();
      await page.waitForTimeout(300); // no write path exists — nothing to poll for

      expect(fs.readFileSync(accPath, 'utf8')).toBe(before);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('cockpit polls acceptance.md while open, picking up an external edit without user interaction (t-96a8)', async ({ page }) => {
    const id = `t-ckpoll-${Date.now()}`;
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] Not yet edited'] });
      const accPath = path.join(dir, 'acceptance.md');
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.locator('.ck-accordion-header[data-accordion="ck-accept-section"]').click();
      await expect(page.locator('#ck-accept')).toContainText('Not yet edited');

      // Simulate the agent (or anyone) editing acceptance.md while the cockpit
      // is open — no cockpit interaction at all, just an external file write.
      fs.writeFileSync(accPath, [
        '# Acceptance', `Ticket: \`${id}\``, '', '## Criteria',
        '- [x] Edited externally while cockpit was open', '',
        '## Test Plan', '- [ ] a check', '', '## QA', '- [ ] Tested locally', '',
      ].join('\n'));

      await expect(page.locator('#ck-accept')).toContainText('Edited externally while cockpit was open', { timeout: 10000 });
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('the shared poll timer starts once per open tab (not per switch) and clears only when the last tab closes (t-96a8/t-8a2a)', async ({ page }) => {
    const id = `t-cktimer-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] a criterion'] });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      // Drive openCockpit/closeCockpit/closeTab directly (not via click+
      // re-render) so this test isolates the timer-lifecycle invariant from
      // board re-render timing. window.openCockpit etc. exist because
      // app.html's script is a plain (non-module) <script> — top-level
      // function declarations attach to window.
      await page.evaluate(id => {
        window.__setIntervalCalls = 0;
        window.__clearIntervalCalls = 0;
        const origSet = window.setInterval, origClear = window.clearInterval;
        window.setInterval = (...a) => { window.__setIntervalCalls++; return origSet(...a); };
        window.clearInterval = (...a) => { window.__clearIntervalCalls++; return origClear(...a); };
      }, id);

      await page.evaluate(id => window.openCockpit(id), id);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      // t-8a2a: "← Board" never touches the shared timer — the tab (and its
      // poll) keeps running hidden in the background.
      await page.evaluate(() => window.closeCockpit());
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);
      await page.waitForLoadState('networkidle');

      // Reopening the SAME already-open tab is a switch, not a fresh mount —
      // must not stack a second setInterval.
      await page.evaluate(id => window.openCockpit(id), id);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      let calls = await page.evaluate(() => ({ set: window.__setIntervalCalls, clear: window.__clearIntervalCalls }));
      expect(calls.set).toBe(1);
      expect(calls.clear).toBe(0);

      // Closing the tab itself (the only one open) is what actually stops it.
      await page.evaluate(id => window.closeTab(id), id);
      calls = await page.evaluate(() => ({ set: window.__setIntervalCalls, clear: window.__clearIntervalCalls }));
      expect(calls.clear).toBeGreaterThanOrEqual(1);

      // A fresh open after the last tab closed starts a new timer again —
      // proving the clear above was real, not a no-op.
      await page.evaluate(id => window.openCockpit(id), id);
      calls = await page.evaluate(() => ({ set: window.__setIntervalCalls, clear: window.__clearIntervalCalls }));
      expect(calls.set).toBe(2);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('opening the cockpit fetches acceptance.md once, not twice, for Acceptance + Test Plan (t-96a8)', async ({ page }) => {
    const id = `t-ckfetch-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] a criterion'] });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      const docFile = `${id}/acceptance.md`;
      let fetchCount = 0;
      await page.route(`**/api/doc/${encodeURIComponent(docFile)}`, route => {
        fetchCount++;
        return route.continue();
      });

      await page.evaluate(id => window.openCockpit(id), id);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      expect(fetchCount).toBe(1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Acceptance and Test Plan accordion sections start collapsed and toggle independently (t-96a8)', async ({ page }) => {
    const id = `t-ckacc-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] a criterion'] });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      const acceptSection = page.locator('#ck-accept-section');
      const testPlanSection = page.locator('#ck-testplan-section');
      // Both start collapsed.
      await expect(acceptSection).toHaveClass(/collapsed/);
      await expect(testPlanSection).toHaveClass(/collapsed/);
      await expect(page.locator('#ck-accept')).toBeHidden();

      await page.locator('.ck-accordion-header[data-accordion="ck-accept-section"]').click();
      await expect(acceptSection).not.toHaveClass(/collapsed/);
      await expect(page.locator('#ck-accept')).toBeVisible();
      // Test Plan untouched by expanding Acceptance.
      await expect(testPlanSection).toHaveClass(/collapsed/);
      await expect(page.locator('#ck-testplan')).toBeHidden();

      await page.locator('.ck-accordion-header[data-accordion="ck-accept-section"]').click();
      await expect(acceptSection).toHaveClass(/collapsed/);
      await expect(page.locator('#ck-accept')).toBeHidden();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Plan section renders plan.md content, including the Gate model line, and starts collapsed', async ({ page }) => {
    const id = `t-ckplan-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', {
        plan: ['# Plan', '', '## Sign-off', 'Tier: normal | Risk: low | Gate model: haiku', '', '- [x] Plan approved', '', '## Approach', 'Filled in with real detail.', ''],
      });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      const planSection = page.locator('#ck-plan-section');
      await expect(planSection).toHaveClass(/collapsed/);
      await expect(page.locator('#ck-plan')).toBeHidden();

      await page.locator('.ck-accordion-header[data-accordion="ck-plan-section"]').click();
      await expect(planSection).not.toHaveClass(/collapsed/);
      await expect(page.locator('#ck-plan')).toContainText('Gate model: haiku');
      await expect(page.locator('#ck-plan')).toContainText('Filled in with real detail');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Plan section shows a hint when this ticket has no plan.md yet', async ({ page }) => {
    const id = `t-cknoplan-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await page.locator('.ck-accordion-header[data-accordion="ck-plan-section"]').click();
      await expect(page.locator('#ck-plan')).toContainText('No plan.md yet');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Acceptance/Test Plan section headers show a checklist item count', async ({ page }) => {
    const id = `t-ckcount-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress', { acceptanceCriteria: ['- [ ] one', '- [x] two', '- [ ] three'] });
      await stubCockpit(page);
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      await expect(page.locator('#ck-accept-count')).toHaveText('(3)');
      // writeTicket's fixed Test Plan body is a single "- [ ] a check" item.
      await expect(page.locator('#ck-testplan-count')).toHaveText('(1)');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });
});

test.describe('cockpit leave-session confirm (t-f6b6)', () => {
  // A minimal fake /cockpit page implementing only the postMessage contract
  // real cockpit.html speaks — no real PTY, no real claude process. Isolates
  // testing of the BOARD side's confirm/save/timeout logic.
  function fakeCockpitPage({ initialStatus = 'running', endDelayMs = 50, forceEndDelayMs = 0 } = {}) {
    return `<!doctype html><html><body><script>
      window.parent.postMessage({source:'canon-cockpit', type:'status', status:${JSON.stringify(initialStatus)}}, '*');
      window.addEventListener('message', function(e){
        var d = e.data;
        if(!d || d.source !== 'canon-cockpit') return;
        if(d.type === 'save-and-end'){
          window.parent.postMessage({source:'canon-cockpit', type:'__received', received:'save-and-end'}, '*');
          setTimeout(function(){ window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*'); }, ${endDelayMs});
        } else if(d.type === 'force-end'){
          window.parent.postMessage({source:'canon-cockpit', type:'__received', received:'force-end'}, '*');
          setTimeout(function(){ window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*'); }, ${forceEndDelayMs});
        }
      });
    </script></body></html>`;
  }

  function writeTicket(id, status) {
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ticket.md'), [
      '---', `id: ${id}`, `status: ${status}`, 'type: feature', 'priority: 2',
      'created: 2026-08-24T00:00:00Z', '---', '', `# Leave-confirm test ${id}`, '',
    ].join('\n'));
  }

  async function openResumedCockpit(page, id, cockpitHtml) {
    await page.route('**/api/cockpit', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:1', launched: true }),
    }));
    await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: cockpitHtml }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await reopenCockpitNoReload(page, id);
  }

  // Opens a cockpit session without navigating — a fresh page.goto would reset
  // all client-side JS state, trivially masking any "stale state carried over
  // from a prior session" bug. Overrides the /cockpit route in place (the most
  // recently registered handler wins) so a second call can serve different
  // fake-page behavior within the same page/session.
  async function reopenCockpitNoReload(page, id, cockpitHtml) {
    if (cockpitHtml) {
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: cockpitHtml }));
    }
    await page.locator('#board-search').fill('');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"] .card-start`).click();
    await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
  }

  test('leaving while running shows the confirm dialog with Save & End and Cancel (no Leave running)', async ({ page }) => {
    const id = `t-lcrun-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running' }));
      await page.waitForTimeout(100); // let the status postMessage land
      await page.locator('#ck-end-session').click();
      const modal = page.locator('#ck-leave-confirm');
      await expect(modal).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-save')).toBeEnabled();
      await expect(page.locator('#ck-leave-leave')).toHaveCount(0);
      await expect(page.locator('#ck-leave-cancel')).toBeVisible();
      // Cancel leaves everything untouched.
      await page.locator('#ck-leave-cancel').click();
      await expect(modal).not.toHaveClass(/open/);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('needs-you disables Save & End with an explanation', async ({ page }) => {
    const id = `t-lcny-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'needs-you' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm')).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-save')).toBeDisabled();
      await expect(page.locator('#ck-leave-confirm-body')).toContainText('waiting on you');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('leaving after the session already finished skips the modal entirely', async ({ page }) => {
    const id = `t-lcdone-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'done' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm')).not.toHaveClass(/open/);
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a live session on a ticket closed meanwhile offers no Save & End (t-b999)', async ({ page }) => {
    const id = `t-lcclosed-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running' }));
      await page.waitForTimeout(100);
      writeTicket(id, 'closed');            // `sprint complete` ran in the terminal; the board's state is stale
      await page.locator('#ck-end-session').click();
      const modal = page.locator('#ck-leave-confirm');
      await expect(modal).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-save')).toBeHidden();
      await expect(page.locator('#ck-leave-confirm-body')).toHaveText(
        'This ticket is closed — there is nothing to save. End without saving to close the session, or Cancel to keep working here.');
      await expect(page.locator('#ck-leave-skip')).toBeVisible();
      await expect(page.locator('#ck-leave-cancel')).toBeVisible();
      for (const theme of ['dark', 'light']) {
        await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
        await page.locator('#ck-leave-confirm .ck-leave-confirm')
          .screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-b999', 'visuals', `closed-leave-${theme}.png`) });
      }
      // The next open of the dialog for a still-open ticket is back to normal.
      await page.locator('#ck-leave-cancel').click();
      writeTicket(id, 'in_progress');
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-save')).toBeVisible();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  // t-2687: End Session on a tab that never attached (status not running) while the daemon still lists
  // a live session for the ticket must not silently close the tab.
  const stubSessions = (page, list) => page.route('**/api/cockpit-sessions', route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify(list),
  }));

  test('End Session on an unattached tab with a live daemon session explains instead of closing (t-2687)', async ({ page }) => {
    const id = `t-lcdet-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await stubSessions(page, [{ session: 's1', ticket: id, project_root: PROJECT_ROOT, cwd: PROJECT_ROOT, agent: '<img src=x onerror=1>', status: 'running' }]);
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'idle' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      const modal = page.locator('#ck-leave-confirm');
      await expect(modal).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-confirm-body')).toContainText("still running in the daemon but isn't attached to this tab");
      await expect(page.locator('#ck-leave-confirm-body')).toContainText('Start sprint to reattach');
      await expect(page.locator('#ck-leave-confirm-body')).toContainText('<img src=x onerror=1>'); // textContent — inert
      await expect(page.locator('#ck-leave-confirm-body img')).toHaveCount(0);
      // A notice, not a choice: the two actions are hidden and the dismiss button reads OK.
      await expect(page.locator('#ck-leave-save')).toBeHidden();
      await expect(page.locator('#ck-leave-skip')).toBeHidden();
      await expect(page.locator('#ck-leave-cancel')).toHaveText('OK');
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/); // the tab is NOT torn down
      await page.locator('#ck-leave-cancel').click();
      await expect(modal).not.toHaveClass(/open/);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);

      // Once the tab really is live, the normal dialog gets its buttons and label back.
      await page.evaluate(() => { cockpitState.status = 'running'; });
      await page.locator('#ck-end-session').click();
      await expect(modal).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-save')).toBeVisible();
      await expect(page.locator('#ck-leave-save')).toBeEnabled();
      await expect(page.locator('#ck-leave-skip')).toBeVisible();
      await expect(page.locator('#ck-leave-cancel')).toHaveText('Cancel');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  for (const [label, list, status] of [
    ['no daemon session', [], 200],
    ['a session for another project root', [{ ticket: 'T-ID', project_root: '/somewhere/else', agent: 'claude', status: 'running' }], 200],
    ['a failed lookup', null, 500],
  ]) {
    test(`End Session on an unattached tab still closes it with ${label} (t-2687)`, async ({ page }) => {
      const id = `t-lcnone-${Date.now()}`;
      try {
        writeTicket(id, 'in_progress');
        await page.route('**/api/cockpit-sessions', route => route.fulfill({
          status, contentType: 'application/json',
          body: JSON.stringify(list ? list.map(x => ({ ...x, ticket: id })) : { error: 'x' }),
        }));
        await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'idle' }));
        await page.waitForTimeout(100);
        await page.locator('#ck-end-session').click();
        await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);
        await expect(page.locator('#ck-leave-confirm')).not.toHaveClass(/open/);
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });
  }

  test('a live tab keeps the normal Save & End dialog even when the daemon lists its session (t-2687)', async ({ page }) => {
    const id = `t-lclive-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await stubSessions(page, [{ session: 's1', ticket: id, project_root: PROJECT_ROOT, agent: 'claude', status: 'running' }]);
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm')).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-save')).toBeEnabled();
      await expect(page.locator('#ck-leave-confirm-body')).not.toContainText("isn't attached");
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a session with an unknown project root still matches by ticket id (t-2687)', async ({ page }) => {
    const id = `t-lcroot-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await stubSessions(page, [{ session: 's1', ticket: id, project_root: '', agent: 'claude', status: 'running' }]);
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'idle' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm-body')).toContainText("isn't attached to this tab");
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  for (const [label, list] of [['finds a session', 'DETACHED'], ['finds nothing', []]]) {
    test(`Start sprint attaching during the sessions lookup gives the live dialog, never a notice or teardown, when the lookup ${label} (t-2687)`, async ({ page }) => {
      const id = `t-lcrace-${Date.now()}`;
      try {
        writeTicket(id, 'in_progress');
        let release;
        const gate = new Promise(r => { release = r; });
        await stubSessions(page, []);
        await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'idle' }));
        await page.waitForTimeout(100);
        await page.route('**/api/cockpit-sessions', async route => {
          await gate;
          await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(
            list === 'DETACHED' ? [{ session: 's1', ticket: id, project_root: PROJECT_ROOT, agent: 'claude', status: 'running' }] : list) });
        });
        await page.locator('#ck-end-session').click();               // lookup pending; tab still un-attached
        await page.evaluate(() => { cockpitState.status = 'running'; }); // ...Start sprint attaches meanwhile
        release();
        await expect(page.locator('#ck-leave-confirm')).toHaveClass(/open/);
        await expect(page.locator('#ck-leave-save')).toBeVisible();
        await expect(page.locator('#ck-leave-save')).toBeEnabled();
        await expect(page.locator('#ck-leave-confirm-body')).not.toContainText("isn't attached");
        await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });
  }

  test('switching tabs while the sessions lookup is in flight applies nothing to the wrong tab (t-2687)', async ({ page }) => {
    const idA = `t-lcswa-${Date.now()}`, idB = `t-lcswb-${Date.now()}`;
    try {
      writeTicket(idA, 'in_progress');
      writeTicket(idB, 'in_progress');
      let release;
      const gate = new Promise(r => { release = r; });
      await stubSessions(page, []); // plain during page load so networkidle can settle
      await openResumedCockpit(page, idA, fakeCockpitPage({ initialStatus: 'idle' }));
      await page.waitForTimeout(100);
      // Gate the lookup only now (the most recently registered route wins).
      await page.route('**/api/cockpit-sessions', async route => {
        await gate;
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([
          { session: 's1', ticket: idA, project_root: PROJECT_ROOT, agent: 'claude', status: 'running' }]) });
      });
      await page.locator('#ck-end-session').click();          // lookup for A now pending
      await page.locator('#ck-back').click();                  // leave the overlay, keep A's tab open
      await reopenCockpitNoReload(page, idB, fakeCockpitPage({ initialStatus: 'running' })); // B becomes the active tab
      await page.waitForTimeout(100);
      release();
      await page.waitForTimeout(400);
      await expect(page.locator('#ck-leave-confirm')).not.toHaveClass(/open/);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', idA), { recursive: true, force: true });
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', idB), { recursive: true, force: true });
    }
  });

  test('Save & End waits for the ended reply before tearing down', async ({ page }) => {
    const id = `t-lcsave-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running', endDelayMs: 400 }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await page.locator('#ck-leave-save').click();
      // Still open immediately after clicking — the fake page hasn't replied yet.
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-confirm-status')).toHaveText('Saving state…');
      // Once the fake page's delayed 'ended' arrives, teardown proceeds.
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 3000 });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('re-clicking Back mid-teardown does not reopen the modal or restart the end sequence (t-9eda)', async ({ page }) => {
    const id = `t-lcreend-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // forceEndDelayMs 2000: comfortable real-wall-clock margin for the two
      // clicks + assertions below to happen before the daemon confirms —
      // cockpitState.status still reads 'running' in this window (only the
      // 'ended' postMessage, not 'status', reports the real end).
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running', forceEndDelayMs: 2000 }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      const modal = page.locator('#ck-leave-confirm');
      await expect(modal).toHaveClass(/open/);
      await page.locator('#ck-leave-skip').click();
      await expect(modal).not.toHaveClass(/open/);
      // Re-click Back while the daemon still hasn't confirmed — must be a
      // no-op (cockpitState._ending guards closeCockpit), not a reopened modal.
      await page.locator('#ck-end-session').click();
      await page.waitForTimeout(50);
      // Immediate, non-retrying check — the daemon's 2s delay means a real
      // reopened modal would still be sitting open right now; a retrying
      // assertion would (wrongly) pass once the real end sequence closes
      // everything ~2s later, masking a transient reopen in between.
      const modalOpenRightNow = await page.locator('#ck-leave-confirm').evaluate(el => el.classList.contains('open'));
      expect(modalOpenRightNow).toBe(false);
      const overlayOpenRightNow = await page.locator('#cockpit-overlay').evaluate(el => el.classList.contains('open'));
      expect(overlayOpenRightNow).toBe(true); // still ending, not torn down yet
      // The original end sequence still completes normally, exactly once.
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 4000 });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('End without saving closes the modal immediately, before the daemon confirms (t-76dc)', async ({ page }) => {
    const id = `t-lcskip-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // forceEndDelayMs 400: the daemon takes a moment to confirm — long enough
      // that a synchronous-close assertion right after the click can't be a
      // timing fluke (it must be optimistic, not just fast).
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running', forceEndDelayMs: 400 }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      const modal = page.locator('#ck-leave-confirm');
      await expect(modal).toHaveClass(/open/);
      const srcBeforeClick = await page.locator('#ck-iframe').evaluate(el => el.src);
      await page.locator('#ck-leave-skip').click();
      // Closes immediately — does not wait for the daemon's 'ended' reply.
      await expect(modal).not.toHaveClass(/open/);
      // The cockpit panel itself and the iframe's src are UNTOUCHED at this
      // point — teardownCockpit() must not have run yet, since the daemon
      // hasn't confirmed. This is the actual safety property: the SSE stream
      // stays alive so a slow/failed kill can still be reported.
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      const srcRightAfterClick = await page.locator('#ck-iframe').evaluate(el => el.src);
      expect(srcRightAfterClick).toBe(srcBeforeClick);
      // The terminal is hidden behind a status message while waiting.
      await expect(page.locator('#ck-iframe')).toHaveCSS('visibility', 'hidden');
      await expect(page.locator('#ck-term-msg')).toHaveText('Ending without saving…');
      // Once the daemon's delayed 'ended' actually arrives, teardown proceeds.
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 3000 });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Save & End on an already-closed ticket skips the save prompt and force-ends (t-98d8)', async ({ page }) => {
    const id = `t-lcclosed-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // endDelayMs 5000: if the short-circuit fails and we fall into save-and-end,
      // the fake page delays 5s before 'ended' — so the 3s teardown assertion (and
      // the force-end capture) both catch it; a pass can't be a timing fluke.
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running', endDelayMs: 5000 }));
      await page.waitForTimeout(100);
      // Simulate `sprint complete` run in the terminal: ticket.md closes on disk
      // while the session stays live. The board's in-memory state stays stale, so
      // the handler must fetch status fresh.
      writeTicket(id, 'closed');
      // Capture which end-message the iframe received (echoed by fakeCockpitPage).
      await page.evaluate(() => {
        window.__received = [];
        window.addEventListener('message', (e) => {
          if (e.data && e.data.type === '__received') window.__received.push(e.data.received);
        });
      });
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm')).toHaveClass(/open/);
      await page.locator('#ck-leave-save').click();
      // Closed ticket → force-end (immediate kill), never the save-state turn.
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 3000 });
      const received = await page.evaluate(() => window.__received);
      expect(received).toContain('force-end');
      expect(received).not.toContain('save-and-end');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Save & End resolves immediately if the session already ended while the modal sat open (t-8efc)', async ({ page }) => {
    const id = `t-lcrace-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // Never replies to save-and-end (huge delay) — if the click handler
      // still waits on the iframe instead of re-checking status, this test
      // would only pass by timing out at endDelayMs, not by resolving fast.
      // A separate timer simulates the daemon's idle-reap 'exit' landing
      // (via the real 'status' postMessage channel) while the modal is open
      // but before Save & End is clicked.
      const html = `<!doctype html><html><body><script>
        window.parent.postMessage({source:'canon-cockpit', type:'status', status:'running'}, '*');
        setTimeout(function(){
          window.parent.postMessage({source:'canon-cockpit', type:'status', status:'done'}, '*');
        }, 150);
        window.addEventListener('message', function(e){
          var d = e.data;
          if(d && d.source === 'canon-cockpit' && d.type === 'save-and-end'){
            setTimeout(function(){ window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*'); }, 60000);
          }
        });
      </script></body></html>`;
      await openResumedCockpit(page, id, html);
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      const modal = page.locator('#ck-leave-confirm');
      await expect(modal).toHaveClass(/open/);
      // Let the delayed 'status: done' land while the modal is still open.
      await page.waitForTimeout(200);
      await expect(modal).toHaveClass(/open/); // still open — idle-reap doesn't touch the modal itself
      await page.locator('#ck-leave-save').click();
      // Resolves right away — no 'Saving state…' wait, no need for the
      // (never-firing, 60s) fake reply or the 90s production fallback.
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 1000 });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a forged ended message not actually from the iframe is ignored', async ({ page }) => {
    const id = `t-lcforge-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // endDelayMs huge: the real reply must never be what completes this test.
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running', endDelayMs: 60000 }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await page.locator('#ck-leave-save').click();
      await expect(page.locator('#ck-leave-confirm-status')).toHaveText('Saving state…');
      // Forged message sent from the TOP frame itself, not the iframe — wrong
      // source and wrong origin. If the board's listener didn't validate
      // e.source/e.origin, this alone would complete the flow.
      await page.evaluate(() => window.postMessage({ source: 'canon-cockpit', type: 'ended' }, '*'));
      await page.waitForTimeout(300);
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-confirm-status')).toHaveText('Saving state…');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('fallback timeout force-ends and warns the save may be incomplete', async ({ page }) => {
    const id = `t-lctimeout-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // Never replies to save-and-end; force-end still gets a reply, exercising the fallback path.
      const html = `<!doctype html><html><body><script>
        window.parent.postMessage({source:'canon-cockpit', type:'status', status:'running'}, '*');
        window.addEventListener('message', function(e){
          var d = e.data;
          if(d && d.source === 'canon-cockpit' && d.type === 'force-end'){
            window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*');
          }
        });
      </script></body></html>`;
      await openResumedCockpit(page, id, html);
      await page.evaluate(() => { window.__cockpitSaveFallbackMs = 300; });
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await page.locator('#ck-leave-save').click();
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 5000 });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('Cancel is disabled mid-save', async ({ page }) => {
    const id = `t-lcreset-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      // Never replies at all — the save just sits "in flight" for this test's purposes.
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running', endDelayMs: 60000 }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await page.locator('#ck-leave-save').click();
      // Mid-save: Cancel must not be clickable — closeLeaveConfirm()
      // alone doesn't abort the pending save-and-end sequence.
      await expect(page.locator('#ck-leave-cancel')).toBeDisabled();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a fresh modal open resets buttons left disabled by a prior session\'s mid-save state', async ({ page }) => {
    const id1 = `t-lcreset1-${Date.now()}`;
    const id2 = `t-lcreset2-${Date.now()}`;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      // Session 1: force a quick fallback so its save-and-end actually completes
      // and tears down, leaving Cancel's disabled=true behind in the DOM
      // (openLeaveConfirm is the only thing that resets it).
      await openResumedCockpit(page, id1, fakeCockpitPage({ initialStatus: 'running', endDelayMs: 60000 }));
      await page.evaluate(() => { window.__cockpitSaveFallbackMs = 200; });
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await page.locator('#ck-leave-save').click();
      await expect(page.locator('#ck-leave-cancel')).toBeDisabled();
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 5000 });

      // Session 2: fresh cockpit, fresh leave-confirm open, SAME page (no
      // reload) — must not inherit session 1's stuck-disabled buttons or
      // leftover "Saving state…" text.
      await reopenCockpitNoReload(page, id2, fakeCockpitPage({ initialStatus: 'running' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm')).toHaveClass(/open/);
      await expect(page.locator('#ck-leave-cancel')).toBeEnabled();
      await expect(page.locator('#ck-leave-save')).toBeEnabled();
      await expect(page.locator('#ck-leave-confirm-status')).toHaveText('');
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('needs-you badge (t-2e7e): shown top-right on needs-you, hidden on running, hidden on reopen', async ({ page }) => {
    const id = `t-badge-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakeCockpitPage({ initialStatus: 'running' }));
      await page.waitForTimeout(100);
      const badge = page.locator('#ck-needs-you-badge');
      await expect(badge).toBeHidden();

      // The board only trusts a status message whose source is the cockpit
      // iframe's own contentWindow, so it must be posted FROM the iframe's
      // frame context, not the top-level page (which would look like an
      // unrelated postMessage the listener correctly ignores).
      const postFromIframe = (status) => page.frameLocator('#ck-iframe').locator('body').evaluate((_, s) => {
        window.parent.postMessage({ source: 'canon-cockpit', type: 'status', status: s }, '*');
      }, status);

      // Flip the fake daemon's status to needs-you without navigating.
      await postFromIframe('needs-you');
      await expect(badge).toBeVisible();
      await expect(badge).toHaveText('!');

      // Back to running clears it again.
      await postFromIframe('running');
      await expect(badge).toBeHidden();

      // A fresh reopen must never inherit a prior session's stale badge state.
      await postFromIframe('needs-you');
      await expect(badge).toBeVisible();
      // "Leave running" was removed (t-a852) — a needs-you session must be
      // resolved before it can be left, so flip to running, then Save & End
      // closes it (fake daemon replies 'ended').
      await postFromIframe('running');
      await page.locator('#ck-end-session').click();
      await page.locator('#ck-leave-save').click();
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 5000 });
      await reopenCockpitNoReload(page, id, fakeCockpitPage({ initialStatus: 'running' }));
      await page.waitForTimeout(100);
      await expect(badge).toBeHidden();
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });
});

test.describe('session sub-tabs (t-8a2a)', () => {
  function writeTicket(id, status) {
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ticket.md'), [
      '---', `id: ${id}`, `status: ${status}`, 'type: feature', 'priority: 2',
      'created: 2026-08-24T00:00:00Z', '---', '', `# Sub-tab test ${id}`, '',
    ].join('\n'));
  }

  // Mirrors the real daemon-served terminal page's own #killBtn contract
  // (tools/cockpit-daemon/web/cockpit.html) closely enough to exercise it:
  // a real POST to /session/<sid>/kill on click, plus the same status/ended
  // postMessage contract every other fake cockpit page in this file speaks.
  function fakeCockpitPageWithKill(sid, { initialStatus = 'running' } = {}) {
    return `<!doctype html><html><body>
      <button id="killBtn" type="button">Kill</button>
      <script>
        window.parent.postMessage({source:'canon-cockpit', type:'status', status:${JSON.stringify(initialStatus)}}, '*');
        document.getElementById('killBtn').addEventListener('click', function(){
          fetch('/session/${sid}/kill', { method: 'POST' }).catch(function(){});
          window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*');
        });
        window.addEventListener('message', function(e){
          var d = e.data;
          if(!d || d.source !== 'canon-cockpit') return;
          if(d.type === 'save-and-end' || d.type === 'force-end'){
            window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*');
          }
          // Echo every received canon-cockpit message back up, tagged
          // distinctly — lets a test assert what THIS tab's own iframe
          // received without needing to monkey-patch a cross-origin window
          // (contentWindow.postMessage can't be redefined from the parent).
          window.parent.postMessage({source:'canon-cockpit', type:'__echo', originalType: d.type}, '*');
        });
      </script>
    </body></html>`;
  }

  async function stubCockpitTabs(page) {
    await page.route('**/api/cockpit', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:1', launched: true }),
    }));
  }

  test('closing a tab sends no kill request; the daemon page\'s own Kill button still does (t-8a2a mitigation test)', async ({ page }) => {
    const id = `t-8a2akill-${Date.now()}`;
    let killRequests = 0;
    try {
      writeTicket(id, 'in_progress');
      await stubCockpitTabs(page);
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fakeCockpitPageWithKill(id) }));
      await page.route('**/session/*/kill', route => {
        killRequests++;
        route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
      });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);

      // Close via the tab strip's "×" — must send NO kill request. The
      // strip renders in two containers (board + topbar); scope to the
      // topbar one, the visible copy while the overlay is open.
      await page.locator(`#ck-tab-strip-topbar .ck-tab-pill-close[data-tab-id="${id}"]`).click();
      await page.waitForTimeout(300);
      expect(killRequests).toBe(0);
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);

      // Positive control: reopening and clicking the daemon page's own Kill
      // button *does* send a real kill request — proves the assertion above
      // isn't passing by accident (e.g. a broken selector firing neither).
      await page.locator('#board-search').fill('');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      await page.frameLocator('#ck-iframe').locator('#killBtn').click();
      await page.waitForTimeout(300);
      expect(killRequests).toBe(1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('starting a second ticket adds a tab without disturbing the first (persistently mounted, no reconnect)', async ({ page }) => {
    const id1 = `t-8a2amulti1-${Date.now()}`;
    const id2 = `t-8a2amulti2-${Date.now()}`;
    let terminalRequests = 0;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await stubCockpitTabs(page);
      await page.route('**/cockpit?**', route => {
        terminalRequests++;
        route.fulfill({ status: 200, contentType: 'text/html', body: fakeCockpitPageWithKill('shared') });
      });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id1);
      await page.locator(`.card[data-id="${id1}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      const firstIframeHandle = await page.locator('#ck-iframe').elementHandle();

      // Back to board to start the second ticket — the overlay covers the
      // board while open, matching the real click-through UX.
      await page.locator('#ck-back').click();
      await page.locator('#board-search').fill('');
      await page.locator('#board-search').fill(id2);
      await page.locator(`.card[data-id="${id2}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);

      await expect(page.locator('#ck-tab-strip-topbar .ck-tab-pill')).toHaveCount(2);
      expect(terminalRequests).toBe(2); // one real mount per NEW tab

      // Switch back to the first tab — its iframe DOM node is the exact same
      // element as before (never destroyed/re-src'd), and switching issues no
      // new terminal request.
      await page.locator(`#ck-tab-strip-topbar .ck-tab-pill[data-tab-id="${id1}"]`).click();
      await expect(page.locator('#ck-id')).toHaveText(id1);
      const iframeStillSame = await page.evaluate(el => el === document.getElementById('ck-iframe'), firstIframeHandle);
      expect(iframeStillSame).toBe(true);
      expect(terminalRequests).toBe(2);
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('"End Session" opens Save & End for the active tab only; a second open tab is unaffected', async ({ page }) => {
    const id1 = `t-8a2aend1-${Date.now()}`;
    const id2 = `t-8a2aend2-${Date.now()}`;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await stubCockpitTabs(page);
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fakeCockpitPageWithKill('shared') }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id1);
      await page.locator(`.card[data-id="${id1}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);

      await page.locator('#ck-back').click();
      await page.locator('#board-search').fill('');
      await page.locator('#board-search').fill(id2);
      await page.locator(`.card[data-id="${id2}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      await expect(page.locator('#ck-tab-strip-topbar .ck-tab-pill')).toHaveCount(2);

      // "← Board" and tab-close never open the modal — only End Session does.
      await expect(page.locator('#ck-leave-confirm')).not.toHaveClass(/open/);
      await page.locator('#ck-end-session').click();
      await expect(page.locator('#ck-leave-confirm')).toHaveClass(/open/);
      await page.locator('#ck-leave-skip').click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/, { timeout: 3000 });

      // Ending tab 2's session removed only that tab; tab 1 is unaffected.
      await expect(page.locator('#ck-tab-strip-topbar .ck-tab-pill')).toHaveCount(1);
      await expect(page.locator(`#ck-tab-strip-topbar .ck-tab-pill[data-tab-id="${id1}"]`)).toBeVisible();
      await expect(page.locator('#ck-id')).toHaveText(id1);
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('"← Board" with 2 tabs open only hides the overlay — no session ends, reopening restores either tab', async ({ page }) => {
    const id1 = `t-8a2aback1-${Date.now()}`;
    const id2 = `t-8a2aback2-${Date.now()}`;
    let killOrEndRequests = 0;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await stubCockpitTabs(page);
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fakeCockpitPageWithKill('shared') }));
      await page.route('**/session/*/kill', route => { killOrEndRequests++; route.fulfill({ status: 200, contentType: 'application/json', body: '{}' }); });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id1);
      await page.locator(`.card[data-id="${id1}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      await page.locator('#ck-back').click();
      await page.locator('#board-search').fill('');
      await page.locator('#board-search').fill(id2);
      await page.locator(`.card[data-id="${id2}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);

      await page.keyboard.press('Escape');
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);
      expect(killOrEndRequests).toBe(0);
      // The board's own tab strip still shows both open tabs.
      await expect(page.locator('#ck-tab-strip .ck-tab-pill')).toHaveCount(2);

      // Reopening either tab restores its view without reconnecting (no
      // /cockpit route hit again — that would only happen on a real remount).
      // Overlay is closed here, so the board's own strip is the visible copy.
      await page.locator(`#ck-tab-strip .ck-tab-pill[data-tab-id="${id1}"]`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await expect(page.locator('#ck-id')).toHaveText(id1);
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('the shared poll relays daemon-build to a background tab without rendering its rail', async ({ page }) => {
    const id1 = `t-8a2apoll1-${Date.now()}`;
    const id2 = `t-8a2apoll2-${Date.now()}`;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await stubCockpitTabs(page);
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fakeCockpitPageWithKill('shared') }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id1);
      await page.locator(`.card[data-id="${id1}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      await page.locator('#ck-back').click();
      await page.locator('#board-search').fill('');
      await page.locator('#board-search').fill(id2);
      await page.locator(`.card[data-id="${id2}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      // Now tab 1 (id1) is backgrounded, tab 2 (id2) is active.

      // Can't monkey-patch a cross-origin iframe's own contentWindow.postMessage
      // from the parent — instead capture what the PARENT receives back: the
      // fake page's own listener (fakeCockpitPageWithKill) echoes every
      // canon-cockpit message it gets as a distinct '__echo' message.
      await page.evaluate(() => {
        window.__echoes = [];
        window.addEventListener('message', (e) => {
          if (e.data && e.data.source === 'canon-cockpit' && e.data.type === '__echo') window.__echoes.push(e.data.originalType);
        });
      });

      // The real timer already started when tab 1 opened (ensureCockpitPollTimer
      // is idempotent and only runs once) — wait a real tick rather than
      // reaching for internals; 5.5s covers the 5000ms interval with margin.
      await page.waitForTimeout(5500);

      const echoes = await page.evaluate(() => window.__echoes);
      // Two tabs are open — a relay reaching only the active one (the old
      // single-session behavior) would echo once; reaching both (this
      // ticket's claim) echoes at least twice in one tick.
      expect(echoes.filter(t => t === 'daemon-build').length).toBeGreaterThanOrEqual(2);
      // The rail itself stays on the active tab (id2) throughout — the poll
      // never swaps it to render the backgrounded tab's own content.
      await expect(page.locator('#ck-id')).toHaveText(id2);
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a background tab\'s needs-you status renders in the tab strip', async ({ page }) => {
    const id1 = `t-8a2aneedsyou1-${Date.now()}`;
    const id2 = `t-8a2aneedsyou2-${Date.now()}`;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await stubCockpitTabs(page);
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fakeCockpitPageWithKill('shared') }));
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id1);
      await page.locator(`.card[data-id="${id1}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      await page.locator('#ck-back').click();
      await page.locator('#board-search').fill('');
      await page.locator('#board-search').fill(id2);
      await page.locator(`.card[data-id="${id2}"] .card-start`).click();
      await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
      await page.waitForTimeout(100);
      // Tab 1 (id1) is now backgrounded.

      // Must originate FROM the background tab's own iframe context (its
      // window.parent.postMessage), not a postMessage sent INTO it from the
      // parent — the board's listener only trusts e.source === that tab's
      // own contentWindow. data-tab-id is stable regardless of active state
      // (unlike id="ck-iframe", which only ever names the active tab).
      await page.frameLocator(`iframe[data-tab-id="${id1}"]`).locator('body').evaluate(() => {
        window.parent.postMessage({ source: 'canon-cockpit', type: 'status', status: 'needs-you' }, '*');
      });
      await page.waitForTimeout(100);

      await expect(page.locator(`#ck-tab-strip-topbar .ck-tab-pill[data-tab-id="${id1}"] .ck-tab-pill-needsyou`)).toBeVisible();
      // The topbar badge stays scoped to the ACTIVE tab (id2), which never
      // received a needs-you status.
      await expect(page.locator('#ck-needs-you-badge')).toBeHidden();
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });
});

test.describe('cockpit preview pane (t-b19b)', () => {
  function writeTicket(id, status) {
    const dir = path.join(PROJECT_ROOT, '.tickets', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ticket.md'), [
      '---', `id: ${id}`, `status: ${status}`, 'type: feature', 'priority: 2',
      'created: 2026-08-24T00:00:00Z', '---', '', `# Preview pane test ${id}`, '',
    ].join('\n'));
  }

  // Simulates what real cockpit.html sends AFTER it has already asked the
  // daemon to validate the reported path (t-b19b's plan.md decision: the
  // daemon re-validates, never trusts the client-relayed path uncomprehendingly)
  // — this fake page only tests the BOARD side's reaction to each outcome.
  function fakePreviewCockpitPage({ respondWith = 'file', delayMs = 30, filePath } = {}) {
    const pathField = filePath === undefined ? '' : `, path:${JSON.stringify(filePath)}`;
    const respond = {
      file: `window.parent.postMessage({source:'canon-cockpit', type:'preview-file', session:'sess1', previewToken:'ptok1', relpath:'index.html'${pathField}}, '*');`,
      'server-cmd': "window.parent.postMessage({source:'canon-cockpit', type:'preview-server-cmd', cmd:'npm run dev'}, '*');",
      timeout: "window.parent.postMessage({source:'canon-cockpit', type:'preview-timeout'}, '*');",
      rejected: "window.parent.postMessage({source:'canon-cockpit', type:'preview-rejected'}, '*');",
      'no-session': "window.parent.postMessage({source:'canon-cockpit', type:'preview-no-session'}, '*');",
    }[respondWith];
    return `<!doctype html><html><body><script>
      window.parent.postMessage({source:'canon-cockpit', type:'status', status:'running'}, '*');
      window.addEventListener('message', function(e){
        var d = e.data;
        if(!d || d.source !== 'canon-cockpit') return;
        if(d.type === 'preview-request'){
          setTimeout(function(){ ${respond} }, ${delayMs});
        } else if(d.type === 'save-and-end' || d.type === 'force-end'){
          window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*');
        }
      });
    </script></body></html>`;
  }

  async function openResumedCockpit(page, id, cockpitHtml) {
    await page.route('**/api/cockpit', route => route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ running: true, addr: '127.0.0.1:1', launched: true }),
    }));
    await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: cockpitHtml }));
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await reopenCockpitNoReload(page, id);
  }

  async function reopenCockpitNoReload(page, id, cockpitHtml) {
    if (cockpitHtml) {
      await page.route('**/cockpit?**', route => route.fulfill({ status: 200, contentType: 'text/html', body: cockpitHtml }));
    }
    await page.locator('#board-search').fill('');
    await page.locator('#board-search').fill(id);
    await page.locator(`.card[data-id="${id}"] .card-start`).click();
    await expect(page.locator('#cockpit-overlay')).toHaveClass(/open/);
  }

  test('PREVIEW_FILE loads a sandboxed iframe pointed at the daemon preview endpoint', async ({ page }) => {
    const id = `t-pvfile-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview')).not.toHaveClass(/collapsed/);
      const iframe = page.locator('#ck-preview-body iframe');
      await expect(iframe).toHaveAttribute('sandbox', 'allow-scripts');
      await expect(iframe).toHaveAttribute('src', 'http://127.0.0.1:1/session/sess1/preview/ptok1/index.html');
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  // --- t-533f: the sandbox silently blocks forms/storage — say so and offer the real file ---
  const NOTE = 'Preview is sandboxed — forms and storage are disabled. Open it in your browser to use the app.';

  test('a static preview shows the sandbox note and Copy file link; the iframe stays sandboxed on the daemon URL (t-533f)', async ({ page, context }) => {
    const id = `t-pvnote-${Date.now()}`;
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file', filePath: 'C:\\Users\\agentops\\Documents\\ToDo\\index.html' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      const note = page.locator('#ck-preview-body .ck-preview-note');
      await expect(note).toContainText(NOTE);
      const btn = note.locator('.ck-preview-copy');
      await expect(btn).toHaveText('Copy file link');
      await expect(btn).toHaveAttribute('aria-label', 'Copy the file link for index.html to open in your browser');
      const iframe = page.locator('#ck-preview-body iframe');
      await expect(iframe).toHaveAttribute('sandbox', 'allow-scripts');
      await expect(iframe).toHaveAttribute('src', 'http://127.0.0.1:1/session/sess1/preview/ptok1/index.html');

      let popups = 0;
      page.on('popup', () => { popups++; });
      const before = page.url();
      await btn.click();
      await expect(note.locator('.ck-preview-copy-status')).toHaveText("Copied — paste it into your browser's address bar.");
      expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('file:///C:/Users/agentops/Documents/ToDo/index.html');
      await page.waitForTimeout(300);
      expect(popups).toBe(0);                              // never opens the daemon URL (it would share the daemon's origin)
      expect(page.url()).toBe(before);
      await expect(iframe).toHaveAttribute('sandbox', 'allow-scripts');
      await expect(iframe).toHaveAttribute('src', 'http://127.0.0.1:1/session/sess1/preview/ptok1/index.html');
      for (const theme of ['dark', 'light']) {
        await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
        await note.screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-533f', 'visuals', `note-${theme}.png`) });
      }
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('fileUrlFor builds a pasteable file:/// URL for POSIX, Windows drive and UNC paths (t-533f)', async ({ page }) => {
    await page.goto(BASE);
    const cases = {
      '/Users/me/My App/index.html': 'file:///Users/me/My%20App/index.html',
      'C:\\Users\\a b\\#1\\index.html': 'file:///C:/Users/a%20b/%231/index.html',
      'c:/proj/index.html': 'file:///C:/proj/index.html',
      '\\\\host\\share\\app\\index.html': 'file://host/share/app/index.html',
      'index.html': '',
      '': '',
    };
    for (const [input, want] of Object.entries(cases)) {
      expect(await page.evaluate(p => fileUrlFor(p), input), input).toBe(want);
    }
  });

  test('without a path (older daemon) the note says where to open the file instead of a dead button (t-533f)', async ({ page }) => {
    const id = `t-pvnopath-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      const note = page.locator('#ck-preview-body .ck-preview-note');
      await expect(note).toContainText(NOTE);
      await expect(note).toContainText('Open index.html from the project folder in your browser.');
      await expect(note.locator('.ck-preview-copy')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('if the clipboard is blocked, the file link is shown selected for a manual copy (t-533f)', async ({ page }) => {
    const id = `t-pvclip-${Date.now()}`;
    await page.addInitScript(() => {
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: () => Promise.reject(new Error('denied')) } });
    });
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file', filePath: '/tmp/my app/index.html' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await page.locator('.ck-preview-copy').click();
      const input = page.locator('.ck-preview-copy-url');
      await expect(input).toHaveValue('file:///tmp/my%20app/index.html');
      await expect(input).toHaveAttribute('readonly', '');
      await expect(input).toBeFocused();
      expect(await input.evaluate(el => [el.selectionStart, el.selectionEnd])).toEqual([0, 'file:///tmp/my%20app/index.html'.length]);
      await expect(page.locator('.ck-preview-copy-status')).toHaveText("Copy this link into your browser's address bar:");
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('PREVIEW_SERVER_CMD shows a static run-yourself message with the exact command, no iframe', async ({ page }) => {
    const id = `t-pvcmd-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'server-cmd' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body')).toContainText('npm run dev');
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('no marker within the timeout shows the fallback message', async ({ page }) => {
    const id = `t-pvto-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'timeout' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body')).toContainText("couldn't determine", { ignoreCase: true });
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('no live session (e.g. idle Resume, pre-Start) shows a message, not an infinite "Asking…"', async ({ page }) => {
    const id = `t-pvnosess-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'no-session' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body')).toContainText('No active sprint session');
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a daemon-rejected path shows a rejection message, not a broken iframe', async ({ page }) => {
    const id = `t-pvrej-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'rejected' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body')).toContainText('rejected');
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('collapse button re-collapses the pane', async ({ page }) => {
    const id = `t-pvcol-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview')).not.toHaveClass(/collapsed/);
      await page.locator('#ck-preview-collapse').click();
      await expect(page.locator('#ck-preview')).toHaveClass(/collapsed/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('a fresh cockpit open never inherits a prior session\'s stale preview content', async ({ page }) => {
    const id1 = `t-pvst1-${Date.now()}`;
    const id2 = `t-pvst2-${Date.now()}`;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await openResumedCockpit(page, id1, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(1);

      await page.locator('#ck-end-session').click();
      // "Leave running" was removed (t-a852); close the live session via Save & End
      // (the fake preview page replies 'ended').
      await page.locator('#ck-leave-save').click();
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/, { timeout: 5000 });

      await reopenCockpitNoReload(page, id2, fakePreviewCockpitPage({ respondWith: 'server-cmd' }));
      await page.waitForTimeout(100);
      await expect(page.locator('#ck-preview')).toHaveClass(/collapsed/);
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(0);
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  // t-82f4: "← Board" then reopening the SAME (still-open) tab must never
  // re-mount the preview iframe or re-ask the agent for it — mirrors t-8a2a's
  // own guarantee for the terminal iframe, extended to the preview pane, which
  // previously had no per-tab state and was unconditionally reset by
  // openCockpit()'s old top-of-function resetPreview() call.
  function fakePreviewCockpitPageCountingRequests({ respondWith = 'file' } = {}) {
    const respond = {
      file: "window.parent.postMessage({source:'canon-cockpit', type:'preview-file', session:'sess1', previewToken:'ptok1', relpath:'index.html'}, '*');",
    }[respondWith];
    return `<!doctype html><html><body><script>
      window.__previewRequestCount = 0;
      window.parent.postMessage({source:'canon-cockpit', type:'status', status:'running'}, '*');
      window.addEventListener('message', function(e){
        var d = e.data;
        if(!d || d.source !== 'canon-cockpit') return;
        if(d.type === 'preview-request'){
          window.__previewRequestCount++;
          setTimeout(function(){ ${respond} }, 30);
        } else if(d.type === 'save-and-end' || d.type === 'force-end'){
          window.parent.postMessage({source:'canon-cockpit', type:'ended'}, '*');
        }
      });
    </script></body></html>`;
  }

  test('"← Board" then reopening the same tab restores the mounted preview iframe without re-requesting it (t-82f4)', async ({ page }) => {
    const id = `t-82f4rt-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPageCountingRequests({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(1);
      // Tag the live iframe node directly (not something app code sets) so a
      // later re-query proves DOM identity, not just a matching src.
      await page.locator('#ck-preview-body iframe').evaluate(el => { el.dataset.mountStamp = 'stamp-1'; });

      await page.locator('#ck-back').click();
      await expect(page.locator('#cockpit-overlay')).not.toHaveClass(/open/);
      await reopenCockpitNoReload(page, id);
      await page.waitForTimeout(100);

      await expect(page.locator('#ck-preview')).not.toHaveClass(/collapsed/);
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(1);
      await expect(page.locator('#ck-preview-body iframe')).toHaveAttribute('data-mount-stamp', 'stamp-1');
      const reqCount = await page.frameLocator('#ck-iframe').locator('body').evaluate(() => window.__previewRequestCount);
      expect(reqCount).toBe(1);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('"← Board" then reopening a tab whose preview was never opened stays collapsed with no iframe (t-82f4)', async ({ page }) => {
    const id = `t-82f4col-${Date.now()}`;
    try {
      writeTicket(id, 'in_progress');
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await expect(page.locator('#ck-preview')).toHaveClass(/collapsed/);

      await page.locator('#ck-back').click();
      await reopenCockpitNoReload(page, id);
      await page.waitForTimeout(100);

      await expect(page.locator('#ck-preview')).toHaveClass(/collapsed/);
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(0);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  test('closing a tab with an open preview frees its iframe from the DOM (t-82f4)', async ({ page }) => {
    const id1 = `t-82f4cl1-${Date.now()}`;
    const id2 = `t-82f4cl2-${Date.now()}`;
    try {
      writeTicket(id1, 'in_progress');
      writeTicket(id2, 'in_progress');
      await openResumedCockpit(page, id1, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click();
      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(1);

      // Back to the board (id1's tab stays open in the background) before
      // opening a SECOND tab — matches how two tabs coexist in real use.
      await page.locator('#ck-back').click();
      await reopenCockpitNoReload(page, id2, fakePreviewCockpitPage({ respondWith: 'server-cmd' }));
      await page.waitForTimeout(100);
      await page.locator(`#ck-tab-strip-topbar .ck-tab-pill-close[data-tab-id="${id1}"]`).click();

      await expect(page.locator('#ck-preview-body iframe')).toHaveCount(0);
    } finally {
      for (const id of [id1, id2]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });

  // t-bc04: status badge next to the ticket id (topbar + rail), colored per status.
  test('status badge shows the ticket status next to the id (t-bc04)', async ({ page }) => {
    const idP = `t-uibp${Date.now().toString().slice(-4)}`;
    try {
      writeTicket(idP, 'in_progress');
      await openResumedCockpit(page, idP, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await expect(page.locator('#ck-status')).toHaveText('in progress');
      await expect(page.locator('#ck-status')).toHaveClass(/st-progress/);
      await expect(page.locator('#ck-tc-status')).toHaveText('in progress');
      await expect(page.locator('#ck-tc-status')).toHaveClass(/st-progress/);
    } finally {
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', idP), { recursive: true, force: true });
    }
  });

  test('preview pane is resizable and collapse still works (t-bc04)', async ({ page }) => {
    const id = `t-uir${Date.now().toString().slice(-4)}`;
    try {
      writeTicket(id, 'in_progress');
      await page.goto(BASE);
      await page.evaluate(() => localStorage.removeItem('ck-preview-w')); // clean baseline
      await openResumedCockpit(page, id, fakePreviewCockpitPage({ respondWith: 'file' }));
      await page.waitForTimeout(100);
      await page.locator('#ck-preview-label').click(); // expand
      await expect(page.locator('#ck-preview')).not.toHaveClass(/collapsed/);
      // t-82f4: the hit target was widened from 7px to 12px (7px was easy to
      // miss with the mouse) — pin the rendered width so it can't silently
      // shrink back.
      const handleBox = await page.locator('#ck-preview-resize').boundingBox();
      expect(handleBox.width).toBeGreaterThanOrEqual(12);
      const widthOf = () => page.locator('#ck-preview').evaluate(el => el.getBoundingClientRect().width);
      const before = await widthOf();
      // Drive the left-edge handle deterministically (synthetic mouse events on the
      // real handler): mousedown on the handle, then mousemove left by 150px → widen.
      await page.evaluate(() => {
        const h = document.getElementById('ck-preview-resize');
        const r = h.getBoundingClientRect();
        const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
        h.dispatchEvent(new MouseEvent('mousedown', { clientX: cx, clientY: cy, bubbles: true }));
        document.dispatchEvent(new MouseEvent('mousemove', { clientX: cx - 150, clientY: cy, bubbles: true }));
        document.dispatchEvent(new MouseEvent('mouseup', { clientX: cx - 150, clientY: cy, bubbles: true }));
      });
      const after = await widthOf();
      expect(after).toBeGreaterThan(before + 40);          // widened
      expect(after).toBeLessThanOrEqual(Math.round(await page.evaluate(() => window.innerWidth * 0.7)) + 2); // clamped
      await page.locator('#ck-preview-collapse').click();  // collapse still works
      await expect(page.locator('#ck-preview')).toHaveClass(/collapsed/);
      expect(await widthOf()).toBeLessThan(60);            // ~40px collapsed
      await page.locator('#ck-preview-label').click();     // expand restores resized width
      expect(await widthOf()).toBeGreaterThan(before + 40);
    } finally {
      await page.evaluate(() => localStorage.removeItem('ck-preview-w')).catch(() => {});
      fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });
});

// Drives the REAL compiled cockpit-daemon end-to-end and asserts the actual
// RENDERED output of a served app-under-test — the gap the 'cockpit preview
// pane (t-b19b)' tests above leave. Those post synthetic messages via
// fakePreviewCockpitPage and assert only the iframe src/sandbox attributes;
// they never render real served bytes. t-b19b's own rendered-output proof was
// a MANUAL live smoke test (its acceptance.md "Live smoke test" line). This
// automates that headlessly: spawn the daemon with a harmless stub command
// (never a real claude/agent), serve a real fixture through the actual
// GET /session/<id>/preview/<token>/<relpath> endpoint, load it into a sandboxed
// iframe that mirrors app.html's renderPreviewFile exactly, and assert the
// rendered DOM + computed style inside the opaque-origin frame. The fixture
// styles via a RELATIVE ./style.css, so the green computed color also proves
// the t-8fbc fix (path-segment token) lets relative sibling assets load.
test.describe('cockpit rendered-output preview (t-8f9d)', () => {
  const os = require('os');
  const DAEMON_SRC = path.join(PROJECT_ROOT, 'tools', 'cockpit-daemon');
  const TICKET = 't-pv01';
  const hasGo = (() => {
    try { execFileSync('go', ['version'], { stdio: 'ignore' }); return true; } catch { return false; }
  })();

  // go build (warm cache) + daemon spawn can exceed the default 30s hook budget.
  test.describe.configure({ timeout: 120_000 });

  let work, daemonBin, stateDir, daemonProc, bootToken;

  test.beforeAll(() => {
    test.skip(!hasGo, 'go toolchain not available — cannot build cockpit-daemon');
    work = fs.mkdtempSync(path.join(os.tmpdir(), 'ck-render-'));

    // A real ticket dir — the daemon's /session/start refuses a ticket that
    // doesn't physically exist in the project (t-842b).
    fs.mkdirSync(path.join(work, '.tickets', TICKET), { recursive: true });
    fs.writeFileSync(path.join(work, '.tickets', TICKET, 'ticket.md'), [
      '---', `id: ${TICKET}`, 'status: open', 'type: task', 'priority: 3',
      'created: 2026-08-24T00:00:00Z', '---', '', `# ${TICKET} render fixture`, '',
    ].join('\n'));

    // Fixture app-under-test. index.html pulls its style from a RELATIVE sibling
    // (./style.css) — so the rendered #marker color only turns green if that
    // sibling actually loaded in the browser. Pre-t-8fbc this failed (the
    // subresource dropped the ?token= and 401'd); with the path-segment token
    // the relative request carries the token and the sibling renders.
    const appDir = path.join(work, 'preview-app');
    fs.mkdirSync(appDir, { recursive: true });
    fs.writeFileSync(path.join(appDir, 'index.html'),
      '<!doctype html><html><head><meta charset="utf-8">' +
      '<link rel="stylesheet" href="./style.css"></head>' +
      '<body><h1 id="marker">canon-preview-rendered-ok</h1></body></html>');
    fs.writeFileSync(path.join(appDir, 'style.css'), '#marker { color: rgb(0, 128, 0); }\n');

    // Harmless stub in place of `claude` — stays alive so the PTY session
    // persists for the duration of the test; never spawns a real agent.
    // t-533f: answers the first prompt it's sent (the preview request) with a
    // PREVIEW_FILE marker line, the way a real agent would — including the other
    // screen text a full-screen TUI leaves on the same row (seen live on Windows).
    const stub = path.join(work, 'stub-agent.sh');
    fs.writeFileSync(stub, '#!/usr/bin/env bash\nread -r _\nprintf "PREVIEW_FILE: %s          ✻Cooked for 2s · done 7:23PM❯ ← for agents\\n" ' +
      JSON.stringify(path.join(work, 'preview-app', 'index.html')) + '\nexec sleep 60\n', { mode: 0o755 });

    // Build and spawn the REAL daemon on an ephemeral loopback port.
    daemonBin = path.join(work, 'cockpit-daemon-test');
    execFileSync('go', ['build', '-o', daemonBin, '.'], { cwd: DAEMON_SRC, stdio: 'inherit' });
    stateDir = path.join(work, 'state');
    bootToken = 'test-boot-token-t8f9d';
    daemonProc = spawn(daemonBin, ['-addr', '127.0.0.1:0'], {
      env: {
        ...process.env,
        COCKPIT_TOKEN: bootToken,
        COCKPIT_SPRINT_BIN: stub,
        COCKPIT_PROJECT_ROOT: work,
        COCKPIT_STATE_DIR: stateDir,
      },
      stdio: 'ignore',
    });
  });

  test.afterAll(() => {
    if (daemonProc) daemonProc.kill('SIGKILL');
    if (work) fs.rmSync(work, { recursive: true, force: true });
  });

  async function daemonAddr() {
    const p = path.join(stateDir, 'daemon.json');
    for (let i = 0; i < 120; i++) {
      try {
        const j = JSON.parse(fs.readFileSync(p, 'utf8'));
        if (j.addr) return j.addr;
      } catch { /* not written yet */ }
      await new Promise(r => setTimeout(r, 50));
    }
    throw new Error('daemon.json addr never appeared');
  }

  test('renders a real served app-under-test through the real daemon preview endpoint', async ({ page, request }) => {
    const base = `http://${await daemonAddr()}`;

    // 1. Start a real session (real daemon, stub agent). Returns the session id,
    //    the session token, and the narrow previewToken.
    const startRes = await request.post(`${base}/session/start`, {
      headers: { Authorization: `Bearer ${bootToken}` },
      data: { ticket: TICKET },
    });
    expect(startRes.status()).toBe(200);
    const started = await startRes.json();
    expect(started.session).toBeTruthy();
    expect(started.previewToken).toBeTruthy();

    // 2. Point the session's preview root at the fixture app dir (real session
    //    token — previewToken is read-only and cannot set the root).
    const prRes = await request.post(`${base}/session/${started.session}/preview-root`, {
      headers: { Authorization: `Bearer ${started.token}` },
      data: { path: path.join(work, 'preview-app', 'index.html') },
    });
    expect(prRes.status()).toBe(204);

    // 3. Render it exactly as app.html's renderPreviewFile does: a sandboxed
    //    iframe (allow-scripts, NO allow-same-origin → opaque origin) whose src
    //    is the real daemon preview endpoint on its own port (cross-origin).
    //    t-8fbc: the previewToken is a PATH segment (…/preview/<token>/<relpath>),
    //    so the relative ./style.css subresource keeps the token and loads.
    const previewUrl = `${base}/session/${encodeURIComponent(started.session)}/preview/${encodeURIComponent(started.previewToken)}/index.html`;
    await page.setContent(
      `<!doctype html><html><body><iframe id="pv" sandbox="allow-scripts" ` +
      `src="${previewUrl}" style="width:600px;height:400px;border:0"></iframe></body></html>`
    );

    // 4. Assert the RENDERED output inside the frame — not the src attribute.
    //    The heading text proves the served HTML reached the DOM of an
    //    opaque-origin (sandbox allow-scripts, no allow-same-origin) frame; the
    //    computed color proves the RELATIVE sibling ./style.css was fetched with
    //    the token (path segment) and applied — the t-8fbc fix, end-to-end.
    const frame = page.frameLocator('#pv');
    await expect(frame.locator('#marker')).toHaveText('canon-preview-rendered-ok');
    const color = await frame.locator('#marker').evaluate(el => getComputedStyle(el).color);
    expect(color).toBe('rgb(0, 128, 0)');

    // 5. Auth preserved: a wrong token in the path segment is rejected 401, and
    //    the sibling served with the correct path token is 200 (the fixed
    //    contract — t-8fbc replaced the old ?token= query form entirely).
    const wrongTok = await request.get(`${base}/session/${started.session}/preview/wrongtoken/style.css`);
    expect(wrongTok.status()).toBe(401);
    const rightTok = await request.get(`${base}/session/${started.session}/preview/${encodeURIComponent(started.previewToken)}/style.css`);
    expect(rightTok.status()).toBe(200);
    expect(await rightTok.text()).toContain('#marker');
  });
  test('the real daemon page relays the accepted absolute path with preview-file (t-533f)', async ({ page, context }) => {
    // Playwright's Chromium blocks a page framing a loopback daemon port under Local Network
    // Access checks unless granted (net::ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS).
    await context.grantPermissions(['local-network-access']);
    const addr = await daemonAddr();
    const want = path.join(work, 'preview-app', 'index.html');
    // A loopback-origin parent (the board's own server), as the real board is — the daemon page
    // only accepts messages from a loopback parent.
    await page.route('**/__pv533f', route => route.fulfill({ status: 200, contentType: 'text/html', body:
      `<!doctype html><html><body><iframe id="ck" style="width:800px;height:400px" ` +
      `src="http://${addr}/cockpit?ticket=${TICKET}&embed=1&autostart=1"></iframe><script>
        window.__msgs = [];
        window.addEventListener('message', function (e) {
          var d = e.data; if (!d || d.source !== 'canon-cockpit') return;
          window.__msgs.push(d);
          if (d.type === 'started') setTimeout(function () {
            document.getElementById('ck').contentWindow.postMessage({ source: 'canon-cockpit', type: 'preview-request' }, '*');
          }, 1500);
        });
      </script></body></html>` }));
    await page.goto(BASE + '/__pv533f');
    await expect.poll(() => page.evaluate(() => (window.__msgs.find(m => m.type === 'preview-file') || null)), { timeout: 30_000 })
      .not.toBeNull();
    const msg = await page.evaluate(() => window.__msgs.find(m => m.type === 'preview-file'));
    expect(msg.relpath).toBe('index.html');
    expect(msg.path).toBe(want);
  });
});

// t-74d6: the cockpit page renders a stale-daemon banner when the board relays
// {stale, running_build, latest_build} via the canon-cockpit postMessage
// channel, and its Restart button calls the token-gated /shutdown. Drives the
// REAL daemon page (loaded directly, not framed — window.parent === window, so
// a self-postMessage satisfies the listener's source/origin checks).
test.describe('cockpit stale-daemon banner (t-74d6)', () => {
  const os = require('os');
  // Anchor to the canon repo (this spec lives in <repo>/tests) rather than
  // PROJECT_ROOT — under SPRINT_CHECK_TEST_ROOT the board root is a fixture dir
  // that has no tools/cockpit-daemon, which would make the build cwd invalid.
  const DAEMON_SRC = path.join(__dirname, '..', 'tools', 'cockpit-daemon');
  test.describe.configure({ timeout: 120_000 });

  let work, daemonBin, bootToken, goOk = false;
  const daemons = []; // every spawned daemon, killed in afterAll

  test.beforeAll(() => {
    // Probe go here (worker process), not at module load: Playwright collects in
    // one process and runs bodies in workers, whose env may lack a spawnable go.
    try { execFileSync('go', ['version'], { stdio: 'ignore' }); goOk = true; }
    catch { goOk = false; return; }
    work = fs.mkdtempSync(path.join(os.tmpdir(), 'ck-stale-'));
    daemonBin = path.join(work, 'cockpit-daemon-test');
    execFileSync('go', ['build', '-o', daemonBin, '.'], { cwd: DAEMON_SRC, stdio: 'inherit' });
    bootToken = 'test-boot-token-t74d6';
    // A real ticket dir so the busy-state test can start a session (the daemon
    // refuses /session/start for a ticket that doesn't physically exist).
    fs.mkdirSync(path.join(work, '.tickets', 't-bnr1'), { recursive: true });
    fs.writeFileSync(path.join(work, '.tickets', 't-bnr1', 'ticket.md'),
      ['---', 'id: t-bnr1', 'status: open', 'type: task', 'priority: 3', 'created: 2026-08-24T00:00:00Z', '---', '', '# banner fixture', ''].join('\n'));
    const stub = path.join(work, 'stub-agent.sh');
    fs.writeFileSync(stub, '#!/usr/bin/env bash\nexec sleep 60\n', { mode: 0o755 });
  });

  test.afterAll(() => {
    for (const d of daemons) { try { d.kill('SIGKILL'); } catch { /* already gone */ } }
    if (work) fs.rmSync(work, { recursive: true, force: true });
  });

  // Spawn a fresh daemon (own state dir) so each test's restart/shutdown is
  // isolated; return its bound addr.
  async function startDaemon() {
    const stateDir = fs.mkdtempSync(path.join(work, 'state-'));
    const stub = path.join(work, 'stub-agent.sh');
    const proc = spawn(daemonBin, ['-addr', '127.0.0.1:0'], {
      env: { ...process.env, COCKPIT_TOKEN: bootToken, COCKPIT_SPRINT_BIN: stub, COCKPIT_PROJECT_ROOT: work, COCKPIT_STATE_DIR: stateDir },
      stdio: 'ignore',
    });
    daemons.push(proc);
    const p = path.join(stateDir, 'daemon.json');
    for (let i = 0; i < 120; i++) {
      try { const j = JSON.parse(fs.readFileSync(p, 'utf8')); if (j.addr) return { addr: j.addr, proc }; } catch { /* not yet */ }
      await new Promise(r => setTimeout(r, 50));
    }
    throw new Error('daemon.json addr never appeared');
  }

  const relay = (info) => (i) => window.postMessage({ source: 'canon-cockpit', type: 'daemon-build', info: i }, '*');
  const STALE = { stale: true, running_build: { version: 'oldbuild', exe_mtime: 1000 }, latest_build: { exe_mtime: 2000 } };

  test('shows the banner (with running build id) when stale, hides it when fresh', async ({ page }) => {
    test.skip(!goOk, 'go toolchain not spawnable in this worker — cannot build cockpit-daemon');
    const { addr, proc } = await startDaemon();
    try {
      await page.goto(`http://${addr}/cockpit?embed=1`);
      const banner = page.locator('#staleBanner');
      await expect(banner).toBeHidden();

      await page.evaluate(relay(), STALE);
      await expect(banner).toBeVisible();
      await expect(page.locator('#sbMsg')).toContainText('out of date');
      await expect(page.locator('#sbMsg')).toContainText('oldbuild');   // running build id
      await expect(page.locator('#sbMsg')).toContainText('latest built'); // latest shown too
      // idle → plain Restart enabled, no Force button.
      await expect(page.locator('#sbRestart')).toBeEnabled();
      await expect(page.locator('#sbForce')).toHaveCount(0);

      // A subsequent non-stale report clears the banner (the board relays this
      // after remounting a fresh daemon).
      await page.evaluate(relay(), { stale: false, running_build: { version: 'oldbuild', exe_mtime: 2000 }, latest_build: { exe_mtime: 2000 } });
      await expect(banner).toBeHidden();
    } finally { proc.kill('SIGKILL'); }
  });

  test('with a live session the plain Restart is disabled and Force restart is confirmed', async ({ page }) => {
    test.skip(!goOk, 'go toolchain not spawnable in this worker — cannot build cockpit-daemon');
    const { addr, proc } = await startDaemon();
    try {
      await page.goto(`http://${addr}/cockpit?ticket=t-bnr1&embed=1`);
      // Start a real (stub) session so the page's status becomes "running".
      await page.locator('#startBtn').click();
      await expect(page.locator('#dot')).toHaveClass(/running/, { timeout: 8000 });

      await page.evaluate(relay(), STALE);
      await expect(page.locator('#staleBanner')).toBeVisible();
      // Busy: plain Restart disabled with the finish-or-Kill message; Force shown.
      await expect(page.locator('#sbRestart')).toBeDisabled();
      await expect(page.locator('#sbMsg')).toContainText('finish or Kill the running session first');
      await expect(page.locator('#sbForce')).toBeVisible();

      // Force restart requires a confirm, then calls /shutdown?force=1 → 200.
      let confirmed = false;
      page.on('dialog', d => { confirmed = true; d.accept(); });
      await page.locator('#sbForce').click();
      await expect(page.locator('#sbMsg')).toContainText('Restarting', { timeout: 5000 });
      expect(confirmed).toBe(true);
    } finally { proc.kill('SIGKILL'); }
  });

  test('Restart on an idle daemon calls /shutdown and reports restarting', async ({ page }) => {
    test.skip(!goOk, 'go toolchain not spawnable in this worker — cannot build cockpit-daemon');
    const { addr, proc } = await startDaemon();
    try {
      await page.goto(`http://${addr}/cockpit?embed=1`);
      await page.evaluate(relay(), STALE);
      await expect(page.locator('#staleBanner')).toBeVisible();
      await expect(page.locator('#sbRestart')).toBeEnabled();

      // Idle daemon (no session) → /shutdown 200 → banner reports restarting.
      await page.locator('#sbRestart').click();
      await expect(page.locator('#sbMsg')).toContainText('Restarting', { timeout: 5000 });
    } finally { proc.kill('SIGKILL'); }
  });
});

test.describe('canon-cockpit Upkeep (t-7ae6)', () => {
  // These test the shell page (tools/sprint-check-app/cockpit.html, served at
  // /cockpit by THIS board's own server), not app.html and not the separate
  // cockpit-daemon binary's own same-named cockpit.html served at a daemon addr.
  const PROJECTS = [{ id: 'proj-a', path: '/tmp/proj-a', name: 'proj-a', description: '', added: '2026-09-15' }];

  async function stubUpkeep(page, { status = { status: 'idle', report_path: '' }, report = null } = {}) {
    await page.route('**/api/projects', route => route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify(PROJECTS),
    }));
    await page.route('**/api/upkeep/status*', route => route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify(status),
    }));
    if (report) {
      await page.route('**/api/upkeep/report*', route => route.fulfill({
        status: 200, contentType: 'application/json', body: JSON.stringify(report),
      }));
    }
  }

  // --- t-7d8d: busy state while a skill registers (skills.sh add is slow on Windows) ---
  // A held /api/register-skill: resolves only when the test calls release(<json>).
  async function stubRegister(page) {
    await page.route('**/api/projects', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(PROJECTS) }));
    let skills = [];
    await page.route('**/api/project-stats*', route => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ updated: '2026-09-24', ticket_count: 0, skills }) }));
    const reg = { calls: 0, release: null };
    await page.route('**/api/register-skill*', async route => {
      reg.calls++;
      const body = await new Promise(r => { reg.release = r; });
      if (body === 'abort') return route.abort();
      if (body.ok) skills = ['sprint'];
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    });
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    return reg;
  }
  const regBtn = (page, skill) => page.locator(`.regskill[data-id="proj-a"][data-skill="${skill}"]`);

  test('registering a skill shows a spinner, disables the card\'s buttons, and sends one request; success reloads (t-7d8d)', async ({ page }) => {
    const reg = await stubRegister(page);
    const sprint = regBtn(page, 'sprint'), eff = regBtn(page, 'efficiency');
    await expect(sprint).toBeVisible();
    await expect(page.locator('.regbtns[data-reg="proj-a"]')).toHaveAttribute('aria-live', 'polite');
    // A visible + <skill> button means the skill is missing: idle border is the theme's red.
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      const red = await page.evaluate(() => {
        const probe = document.createElement('span'); probe.style.color = 'var(--col-discarded)'; document.body.appendChild(probe);
        const c = getComputedStyle(probe).color; probe.remove(); return c;
      });
      expect(await sprint.evaluate(e => getComputedStyle(e).borderTopColor)).toBe(red);
      await page.locator('.regbtns[data-reg="proj-a"]').screenshot({ path: path.join(require('os').tmpdir(), `canon-regskill-needed-${theme}.png`) });
    }
    await sprint.click();
    await page.locator('#cc-ok').click();
    await expect(sprint).toContainText('Adding sprint…');
    await expect(sprint.locator('.reg-spin')).toBeVisible();
    await expect(sprint).toHaveAttribute('aria-busy', 'true');
    await expect(sprint).toBeDisabled();
    await expect(eff).toBeDisabled();
    await sprint.dblclick({ force: true });
    await eff.click({ force: true });
    await expect(page.locator('#cconfirm')).not.toHaveClass(/show/);
    expect(reg.calls).toBe(1);
    const seen = new Set();
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      const accent = await page.evaluate(() => {   // --accent resolved to rgb() the same way the spinner's colour is
        const probe = document.createElement('span'); probe.style.color = 'var(--accent)'; document.body.appendChild(probe);
        const c = getComputedStyle(probe).color; probe.remove(); return c;
      });
      const spin = await sprint.locator('.reg-spin').evaluate(e => getComputedStyle(e).borderTopColor);
      expect(spin).toBe(accent);
      seen.add(spin);
      await page.locator('.regbtns[data-reg="proj-a"]').screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-7d8d', 'visuals', `busy-${theme}.png`) });
    }
    expect(seen.size).toBe(2);              // the spinner follows the theme, not a fixed colour
    reg.release({ ok: true });
    await expect(page.locator('#toast')).toContainText('Registered sprint in proj-a');
    await expect(sprint).toBeHidden();      // reloaded: sprint is now registered
    await expect(eff).toBeEnabled();
    await expect(eff).toHaveText('+ efficiency');
  });

  test('after an error, a failed request, or unsupported, the register buttons come back (t-7d8d)', async ({ page }) => {
    const reg = await stubRegister(page);
    const sprint = regBtn(page, 'sprint'), eff = regBtn(page, 'efficiency');
    for (const outcome of [{ ok: false, error: 'boom' }, 'abort', { unsupported: true, cmd: 'skills.sh add sprint /tmp/proj-a' }]) {
      await sprint.click();
      await page.locator('#cc-ok').click();
      await expect(sprint).toBeDisabled();
      reg.release(outcome);
      if (outcome.unsupported) {
        await expect(page.locator('#cc-title')).toContainText('manually');
        await expect(sprint).toBeEnabled();  // restored before the manual-command dialog, not behind it
        await page.locator('#cc-ok').click();
      }
      for (const [b, label] of [[sprint, '+ sprint'], [eff, '+ efficiency']]) {
        await expect(b).toBeEnabled();
        await expect(b).toHaveText(label);
        expect(await b.getAttribute('aria-busy')).toBeNull();
      }
    }
    expect(reg.calls).toBe(3);
  });

  test('a run in flight blocks a second one for the same project even after the cards re-render (t-7d8d)', async ({ page }) => {
    const reg = await stubRegister(page);
    await regBtn(page, 'sprint').click();
    await page.locator('#cc-ok').click();
    await expect(regBtn(page, 'sprint')).toBeDisabled();
    await page.evaluate(() => load());      // re-render: fresh, enabled buttons (e.g. another project's run finished)
    await expect(regBtn(page, 'efficiency')).toBeEnabled();
    await regBtn(page, 'efficiency').click();
    await expect(page.locator('#cconfirm')).not.toHaveClass(/show/);   // no second confirm, no second run
    expect(reg.calls).toBe(1);
    reg.release({ ok: false, error: 'x' });
  });

  test('the in-project Register sprint bar shows the same busy state, not dimmed, and comes back (t-7d8d)', async ({ page }) => {
    const reg = await stubRegister(page);
    await page.locator('.go[data-open="proj-a"]').click();
    const bar = page.locator('.sn-reg');
    await expect(bar).toBeVisible();
    await expect(page.locator('.sn-actions')).toHaveAttribute('aria-live', 'polite');
    await bar.click();
    await page.locator('#cc-ok').click();
    await expect(bar).toContainText('Adding sprint…');
    await expect(bar.locator('.reg-spin')).toBeVisible();
    await expect(bar).toHaveAttribute('aria-busy', 'true');
    await expect(bar).toBeDisabled();
    expect(await bar.evaluate(e => getComputedStyle(e).opacity)).toBe('1');   // busy, not the dimmed .btn:disabled look
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      await bar.screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-7d8d', 'visuals', `bar-busy-${theme}.png`) });
    }
    reg.release({ ok: false, error: 'x' });
    await expect(bar).toBeEnabled();
    await expect(bar).toHaveText('Register sprint');
    expect(reg.calls).toBe(1);
  });

  test('cancelling the register confirm sends nothing and leaves the buttons alone (t-7d8d)', async ({ page }) => {
    const reg = await stubRegister(page);
    const sprint = regBtn(page, 'sprint');
    await sprint.click();
    await page.locator('#cc-cancel').click();
    await expect(sprint).toBeEnabled();
    await expect(sprint).toHaveText('+ sprint');
    expect(reg.calls).toBe(0);
  });

  test('the register spinner does not animate under prefers-reduced-motion (t-7d8d)', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    const reg = await stubRegister(page);
    const sprint = regBtn(page, 'sprint');
    await sprint.click();
    await page.locator('#cc-ok').click();
    expect(await sprint.locator('.reg-spin').evaluate(e => getComputedStyle(e).animationName)).toBe('none');
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    expect(await sprint.locator('.reg-spin').evaluate(e => getComputedStyle(e).animationName)).toBe('reg-spin');
    reg.release({ ok: false, error: 'x' });
  });

  test('Upkeep nav item is present and switches to its own view', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('#nav-upkeep')).toContainText('Upkeep');
    await page.locator('#nav-upkeep').click();
    await expect(page.locator('#view-upkeep')).toHaveClass(/active/);
    await expect(page.locator('#view-projects')).not.toHaveClass(/active/);
    await expect(page.locator('#nav-upkeep')).toHaveClass(/active/);
    await expect(page.locator('#nav-projects')).not.toHaveClass(/active/);
    // All 4 skills render as cards.
    for (const id of ['context-check', 'context-doctor', 'dead-code-cleanup', 'promote-learnings']) {
      await expect(page.locator('#up-card-' + id)).toBeVisible();
    }
  });

  test('context-check "?" popover mentions trend tracking against the last run (t-c957)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();
    await page.locator('#up-card-context-check .rc-help').click();
    await expect(page.locator('#up-help-context-check')).toContainText(
      'compares its finding count to your last run on this repo');
  });

  test('promote-learnings and dead-code-cleanup "?" popovers name the concrete next step (t-a27a)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();

    await page.locator('#up-card-promote-learnings .rc-help').click();
    await expect(page.locator('#up-help-promote-learnings')).toContainText(
      'no promote command');

    await page.locator('#up-card-dead-code-cleanup .rc-help').click();
    await expect(page.locator('#up-help-dead-code-cleanup')).toContainText(
      'interactive session'); // exact phrasing moved into its own section, t-d05b
  });

  test('promote-learnings "?" popover mentions direct invocation and a captured example (t-5dd4)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();
    await page.locator('#up-card-promote-learnings .rc-help').click();
    const panel = page.locator('#up-help-promote-learnings');
    await expect(panel).toContainText('/promote-learnings');
    await expect(panel).toContainText('Example output');
    await expect(panel).toContainText('not a live preview');
    await expect(panel).toContainText('standards/efficiency.md');
    await expect(panel).toContainText('dismiss');
  });

  test('promote-learnings "?" popover covers the consumer PROMOTED.md path (t-8b55)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();
    await page.locator('#up-card-promote-learnings .rc-help').click();
    // Look sections up by their heading element, not by text order (the t-f5ab jump link repeats "What to do next").
    const section = (name) => page.locator('#up-help-promote-learnings .rc-pop-sec')
      .filter({ has: page.locator('.rc-pop-eyebrow', { hasText: new RegExp(`^${name}$`, 'i') }) }).innerText();
    expect(await section('Why it runs')).toContain('PROMOTED.md');
    expect(await section('Example output — from a past run, not a live preview')).toContain('In canon, this skill never writes');
    expect(await section('What to do next')).toContain('PROMOTED.md');
    expect(await section('What to do next')).toMatch(/^What to do next\s*To move the learnings, run \/promote-learnings in an interactive session/i);
    expect(await section('What it does not do')).toContain('PROMOTED.md');
    await page.locator('#up-help-promote-learnings').screenshot({ path: test.info().outputPath('promote-learnings-help.png') });
  });

  test('"What to do next" renders in the theme green with an unobstructed jump link (t-f5ab)', async ({ page }) => {
    await page.setViewportSize({ width: 1300, height: 900 }); // promote-learnings' "?" opens upward at this size
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();
    await page.locator('#up-card-promote-learnings .rc-help').click();
    const panel = page.locator('#up-help-promote-learnings');
    await expect(panel).toHaveClass(/\bup\b/);
    const next = panel.locator('.rc-pop-sec.next');
    await expect(next.locator('.rc-pop-eyebrow')).toHaveText(/what to do next/i);

    for (const [theme, green, muted] of [['dark', 'rgb(74, 222, 128)', 'rgb(151, 161, 180)'], ['light', 'rgb(22, 163, 74)', 'rgb(82, 82, 122)']]) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      await expect(next.locator('.rc-pop-eyebrow')).toHaveCSS('color', green);
      await expect(next).toHaveCSS('border-left-color', green);
      await expect(panel.locator('.rc-pop-sec:not(.next) .rc-pop-eyebrow').first()).toHaveCSS('color', muted);
    }

    // The link sits between the lead and the first section.
    const order = await panel.evaluate(p => [...p.querySelector('.rc-pop-body').children].map(c => c.className));
    expect(order.indexOf('rc-pop-jump')).toBe(order.indexOf('rc-pop-lead') + 1);
    expect(order.indexOf('rc-pop-jump')).toBeLessThan(order.findIndex(c => c.startsWith('rc-pop-sec')));

    // Nothing (top bar, tab strip) covers the element: the topmost element at its centre is inside the panel.
    const unobstructed = sel => panel.locator(sel).first().evaluate(e => {
      const r = e.getBoundingClientRect(), hit = document.elementFromPoint(r.left + 20, r.top + r.height / 2);
      return !!hit && !!hit.closest('.rc-pop');
    });
    expect(await unobstructed('.rc-pop-title')).toBe(true);
    expect(await unobstructed('.rc-pop-jump')).toBe(true);

    const pageY = await page.evaluate(() => window.scrollY);
    await panel.locator('.rc-pop-jump').click();
    await expect.poll(() => unobstructed('.rc-pop-sec.next .rc-pop-eyebrow')).toBe(true);
    expect(await page.evaluate(() => window.scrollY)).toBe(pageY);
  });

  test('promote-learnings and skill-eval "?" popovers render numbered lists on separate lines (t-4254)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();
    await expect(page.locator('#se-card .rc-title')).toBeVisible(); // seRender runs after the grid

    await page.locator('#up-card-promote-learnings .rc-help').click();
    const learningsHtml = await page.locator('#up-help-promote-learnings').innerHTML();
    expect(learningsHtml).toContain('<br><b>2</b>');
    expect(learningsHtml).toContain('<br><b>3</b>');

    await page.locator('[data-help="skill-eval"] .rc-help').click({ force: true });
    const skillEvalHtml = await page.locator('#up-help-skill-eval').innerHTML();
    expect(skillEvalHtml).toContain('<br><b>2 Best practices</b>');
    expect(skillEvalHtml).toContain('<br><b>3 Plugin eval</b>');
  });

  test('all 5 Upkeep "?" popovers have a "What to do next" section (t-d05b)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.locator('#nav-upkeep').click();
    await expect(page.locator('#se-card .rc-title')).toBeVisible(); // seRender runs after the grid

    const cases = [
      ['context-check', 'Trend line move'],
      ['context-doctor', "claude-optimization.md"],
      ['dead-code-cleanup', 'review candidates and confirm removals'],
      ['promote-learnings', 'no promote command'],
      ['skill-eval', 'Open the full report'],
    ];
    for (const [id, snippet] of cases) {
      await page.locator(`[data-help="${id}"] .rc-help`).click({ force: true });
      const panel = page.locator(`#up-help-${id}`);
      await expect(panel).toContainText('What to do next', { ignoreCase: true });
      await expect(panel).toContainText(snippet);
      await page.locator(`[data-help="${id}"] .rc-help`).click({ force: true }); // close before next
    }

    // dead-code-cleanup/promote-learnings: the moved sentences must appear only
    // once each in the panel, not duplicated between the new section and
    // "What it does not do".
    await page.locator('[data-help="dead-code-cleanup"] .rc-help').click({ force: true });
    const deadCodeText = await page.locator('#up-help-dead-code-cleanup').innerText();
    expect(deadCodeText.match(/review candidates and confirm removals/g)?.length ?? 0).toBe(1);
    await page.locator('[data-help="dead-code-cleanup"] .rc-help').click({ force: true });

    await page.locator('#up-card-promote-learnings .rc-help').click();
    const learningsText = await page.locator('#up-help-promote-learnings').innerText();
    expect(learningsText.match(/no promote command/g)?.length ?? 0).toBe(1);
  });

  test('clicking a Projects tab clears the Upkeep nav active state (t-5dc2 3-way switch)', async ({ page }) => {
    await stubUpkeep(page);
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-upkeep').click();
    await expect(page.locator('#nav-upkeep')).toHaveClass(/active/);
    await page.locator('#nav-projects').click();
    await expect(page.locator('#nav-upkeep')).not.toHaveClass(/active/);
    await expect(page.locator('#nav-projects')).toHaveClass(/active/);
  });

  test('clicking Run posts the project as a URL query param, not just the JSON body (t-7ae6 live-caught bug)', async ({ page }) => {
    await stubUpkeep(page);
    let capturedUrl = '';
    await page.route('**/api/upkeep/run*', route => {
      capturedUrl = route.request().url();
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, status: 'running' }) });
    });
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-upkeep').click();
    await page.locator('#up-card-context-check button:has-text("Run")').click();
    await expect(page.locator('#cc-ok')).toBeVisible();
    await page.locator('#cc-ok').click();
    await expect.poll(() => capturedUrl).toContain('project=proj-a');
  });

  test('a running skill disables its Agent/Model selects and Run button, and polling clears it', async ({ page }) => {
    let pollCount = 0;
    await page.route('**/api/projects', route => route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify(PROJECTS),
    }));
    await page.route('**/api/upkeep/status*', route => {
      pollCount++;
      const running = pollCount <= 1; // first read: running; poll tick: done
      route.fulfill({
        status: 200, contentType: 'application/json',
        body: JSON.stringify(running
          ? { status: 'running', report_path: '', elapsed: 1 }
          : { status: 'done', report_path: '/tmp/proj-a/.reports/context-check_x.md', finished_at: Date.now() / 1000 }),
      });
    });
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-upkeep').click();
    await expect(page.locator('#up-card-context-check .up-status.run')).toBeVisible();
    await expect(page.locator('#up-card-context-check .rc-select').first()).toBeDisabled();
    await expect(page.locator('#up-card-context-check')).toContainText('locked while running');
    // A disabled Run must also look disabled (the global .btn had no disabled style).
    const runBtn = page.locator('#up-card-context-check .rc-actions .btn').first();
    await expect(runBtn).toBeDisabled();
    await expect(runBtn).toHaveCSS('cursor', 'not-allowed');
    await expect(runBtn).not.toHaveCSS('opacity', '1');
    // A real hover on a disabled button never matches reliably, so force :hover through CDP and read the computed filter.
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('DOM.enable'); await cdp.send('CSS.enable');
    const { root } = await cdp.send('DOM.getDocument');
    const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: root.nodeId, selector: '#up-card-context-check .rc-actions .btn' });
    await cdp.send('CSS.forcePseudoState', { nodeId, forcedPseudoClasses: ['hover'] });
    await page.waitForTimeout(400); // let any filter transition finish before reading
    // Read once, without toHaveCSS's auto-retry: the 3s poll re-renders the card, and a retry would eventually
    // read the fresh, un-hovered button and pass even with the rule removed.
    expect(await runBtn.evaluate(el => getComputedStyle(el).filter)).toBe('none'); // a disabled button must not brighten on hover
    // Poll interval is 3s in the client; wait long enough for one tick to land.
    await expect(page.locator('#up-card-context-check .up-status.ok, #up-card-context-check .up-status.run')).toHaveCount(1, { timeout: 6000 });
  });

  test('View report renders findings as amber callouts and bold text, read from the report endpoint', async ({ page }) => {
    await stubUpkeep(page, {
      status: { status: 'done', report_path: '/tmp/proj-a/.reports/context-check_x.md', finished_at: Date.now() / 1000 },
      report: { ok: true, path: '/tmp/proj-a/.reports/context-check_x.md',
        content: '# Report\n\n**Summary:** all clear.\n\nSome **bold** prose.\n\n## Findings\n\n- `AGENTS.md:1` a finding.\n\n## Next Steps\n\nDo the thing.\n' },
    });
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-upkeep').click();
    await page.locator('#up-card-context-check button:has-text("View report")').click();
    await expect(page.locator('#up-detail')).toHaveClass(/open/);
    // A leading `**Label:** value` line is a meta chip (5e5a6cf), not inline bold: <b> inside .up-meta .um.
    await expect(page.locator('#up-rp-body .up-meta .um b')).toContainText('Summary');
    await expect(page.locator('#up-rp-body .up-meta .um')).toContainText('all clear.');
    await expect(page.locator('#up-rp-body p strong')).toContainText('bold');
    await expect(page.locator('#up-rp-body ul.up-findings li')).toContainText('AGENTS.md:1');
    await expect(page.locator('#up-rp-body')).toContainText('Next Steps');
  });
});

test.describe('canon-cockpit Skill Eval card (t-23d8)', () => {
  const PROJECTS = [{ id: 'proj-a', path: '/tmp/proj-a', name: 'proj-a', description: '', added: '2026-09-15' }];
  const chk = (id, stage, status, evidence = 'ok', fix = '') => ({ id, stage, status, evidence, fix });
  const GOOD = {
    ok: true, skill: 'api', skill_dir: '/tmp/proj-a/skills/api',
    checks: [chk('evals-present', 1, 'pass'), chk('evals-variety', 1, 'warn', 'one case type', 'Mix case types'),
             chk('frontmatter', 2, 'pass'), chk('body-length', 2, 'pass')],
  };
  const NOEVALS = {
    ok: true, skill: 'api', skill_dir: '/tmp/proj-a/skills/api',
    checks: [chk('evals-present', 1, 'fail', 'evals.json not found', 'Create evals/evals.json'), chk('frontmatter', 2, 'pass')],
  };
  const HOOKS = { ...GOOD, checks: [...GOOD.checks, chk('trust-hooks', 2, 'warn', 'frontmatter registers hooks', 'Review the hook commands')] };

  async function setup(page, { check, statuses = [{ ok: true, status: 'never' }], run = { ok: true, status: 'running' }, capture = {} }) {
    await page.route('**/api/projects', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(PROJECTS) }));
    await page.route('**/api/upkeep/status*', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ status: 'idle', report_path: '' }) }));
    await page.route('**/api/browse-dirs*', route => {
      const path = new URL(route.request().url()).searchParams.get('path');
      const body = path === '/tmp/proj-a'
        ? { path, parent: '/tmp', entries: [{ name: 'skills', path: '/tmp/proj-a/skills' }] }
        : { path, parent: '/tmp/proj-a', entries: [{ name: 'api', path: '/tmp/proj-a/skills/api' }] };
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    });
    await page.route('**/api/skill-eval/check*', route => {
      capture.checkUrl = route.request().url(); capture.checkBody = route.request().postData();
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(check) });
    });
    let n = 0;
    await page.route('**/api/skill-eval/status*', route => {
      const body = statuses[Math.min(n++, statuses.length - 1)];
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    });
    await page.route('**/api/skill-eval/run*', route => {
      capture.runUrl = route.request().url(); capture.runBody = JSON.parse(route.request().postData());
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(run) });
    });
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-upkeep').click();
  }
  async function pick(page) {
    await page.locator('#se-card button:has-text("Browse")').click();
    await expect(page.locator('#se-card .dirnav-path')).toHaveText('/tmp/proj-a');
    await expect(page.locator('#se-card .dirnav-row:has-text("skills")')).toBeVisible(); // list loaded
    await expect(page.locator('#se-card .dirnav-row.up')).toHaveCount(0); // never above the project root
    await page.locator('#se-card .dirnav-row:has-text("skills")').click();
    await expect(page.locator('#se-card .dirnav-row:has-text("api")')).toBeVisible();
    await expect(page.locator('#se-card .dirnav-row.up')).toHaveCount(1);
    await page.locator('#se-card .dirnav-row:has-text("api")').click();
    await page.locator('#se-card button:has-text("Use this folder")').click();
  }

  test('browse starts at the project root, cannot go above it, and checks the picked folder with ?project=', async ({ page }) => {
    const capture = {};
    await setup(page, { check: GOOD, capture });
    await expect(page.locator('#se-card')).toBeVisible();
    await pick(page);
    await expect(page.locator('#se-card')).toContainText('Eval coverage');
    await expect(page.locator('#se-card')).toContainText('Best practices');
    await expect(page.locator('#se-card')).toContainText('evals-variety');
    await expect(page.locator('#se-card')).toContainText('Mix case types');
    expect(capture.checkUrl).toContain('project=proj-a');
    expect(JSON.parse(capture.checkBody).skill_dir).toBe('/tmp/proj-a/skills/api');
  });

  test('a stale board server (404 without JSON) says to restart it, not "request failed"', async ({ page }) => {
    await setup(page, { check: GOOD });
    await page.route('**/api/skill-eval/check*', route => route.fulfill({ status: 404, contentType: 'text/plain', body: 'Not Found' }));
    await pick(page);
    await expect(page.locator('#se-card .se-err')).toContainText('older than this page');
    await expect(page.locator('#se-card .se-err')).toContainText('Restart it');
    await expect(page.locator('#se-card')).not.toContainText('request failed');
  });

  test('an unreachable board server says so', async ({ page }) => {
    await setup(page, { check: GOOD });
    await page.route('**/api/skill-eval/check*', route => route.abort());
    await pick(page);
    await expect(page.locator('#se-card .se-err')).toContainText('Could not reach the board server');
  });

  test('a non-JSON server error names the HTTP status', async ({ page }) => {
    await setup(page, { check: GOOD });
    await page.route('**/api/skill-eval/check*', route => route.fulfill({ status: 500, contentType: 'text/html', body: '<h1>boom</h1>' }));
    await pick(page);
    await expect(page.locator('#se-card .se-err')).toContainText('unexpected reply (HTTP 500)');
  });

  test('a stale server on Run shows the restart message too', async ({ page }) => {
    await setup(page, { check: GOOD });
    await pick(page);
    await page.route('**/api/skill-eval/run*', route => route.fulfill({ status: 404, contentType: 'text/plain', body: 'Not Found' }));
    await page.locator('#se-card button:has-text("Run plugin eval")').click();
    await page.locator('#cc-ok').click();
    await expect(page.locator('#se-card .se-err')).toContainText('Restart it');
  });

  test('a failing check locks stage 3: no Run button, nothing spent', async ({ page }) => {
    await setup(page, { check: NOEVALS });
    await pick(page);
    await expect(page.locator('#se-card')).toContainText('Create evals/evals.json');
    await expect(page.locator('#se-card')).toContainText('Fix the failing check');
    await expect(page.locator('#se-card button:has-text("Run plugin eval")')).toHaveCount(0);
  });

  test('a server refusal is shown and the folder is cleared', async ({ page }) => {
    await setup(page, { check: { ok: false, error: 'skill folder must be inside the selected project' } });
    await pick(page);
    await expect(page.locator('#se-card .se-err')).toContainText('must be inside the selected project');
    await expect(page.locator('#se-card .se-steps')).toHaveCount(0);
  });

  test('run: cost confirm names plan usage, sends confirm_cost, then shows scores and a report link', async ({ page }) => {
    const capture = {};
    const done = { ok: true, status: 'done', finished_at: Date.now() / 1000, report_path: '/x/report.html',
      summary: { casesTotal: 2, casesPassed: 2, overallScore: 1, meanDelta: 0.5, costUsd: 0.42,
                 cases: [{ name: 'api-1', with: 1, without: 0 }, { name: 'api-2', with: 1, without: 1 }] } };
    await setup(page, { check: GOOD, statuses: [{ ok: true, status: 'never' }, done], capture });
    await pick(page);
    await page.locator('#se-card button:has-text("Run plugin eval")').click();
    await expect(page.locator('#cc-body')).toContainText('plan usage');
    await page.locator('#cc-ok').click();
    await expect.poll(() => capture.runBody && capture.runBody.confirm_cost).toBe(true);
    expect(capture.runBody.allow_trust).toBe(false);
    expect(capture.runUrl).toContain('project=proj-a');
    await expect(page.locator('#se-card .se-tiles')).toContainText('$0.42', { timeout: 10000 });
    await expect(page.locator('#se-card .se-tiles')).toContainText('+0.50');
    await expect(page.locator('#se-card')).toContainText('api-1');
    const href = await page.locator('#se-card a:has-text("Open full report")').getAttribute('href');
    expect(href).toContain('/api/skill-eval/report.html?project=proj-a');
    expect(href).toContain(encodeURIComponent('/tmp/proj-a/skills/api'));
  });

  test('a skill with hooks needs an explicit acknowledgement before Run is enabled', async ({ page }) => {
    const capture = {};
    await setup(page, { check: HOOKS, capture });
    await pick(page);
    const run = page.locator('#se-card button:has-text("Run plugin eval")');
    await expect(run).toBeDisabled();
    // It must also LOOK disabled (the global .btn has no disabled style) and say how to enable it.
    await expect(run).toHaveCSS('cursor', 'not-allowed');
    await expect(run).not.toHaveCSS('opacity', '1');
    await expect(page.locator('#se-card')).toContainText('Tick the box below to enable Run');
    const box = await page.locator('#se-card .se-ack input').boundingBox();
    expect(box.width).toBeGreaterThanOrEqual(16); // the browser default (~13px) read as tiny next to the button
    await page.locator('#se-card label:has-text("trust-hooks") input').check();
    await expect(run).toBeEnabled();
    await expect(run).toHaveCSS('opacity', '1');
    await expect(page.locator('#se-card')).not.toContainText('Tick the box below');
    await run.click();
    await page.locator('#cc-ok').click();
    await expect.poll(() => capture.runBody && capture.runBody.allow_trust).toBe(true);
  });
});

test.describe('canon-cockpit "?" info popovers (t-576f)', () => {
  const PROJECTS = [{ id: 'proj-a', path: '/tmp/proj-a', name: 'proj-a', description: '', added: '2026-09-15' }];
  const CARDS = ['context-check', 'context-doctor', 'dead-code-cleanup', 'promote-learnings', 'skill-eval'];
  async function open(page, width = 1100) {
    await page.setViewportSize({ width, height: 900 });
    await page.route('**/api/projects', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(PROJECTS) }));
    await page.route('**/api/upkeep/status*', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ status: 'idle', report_path: '' }) }));
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-upkeep').click();
    await expect(page.locator('#up-card-context-check')).toBeVisible();
    await expect(page.locator('#se-card .rc-title')).toBeVisible();   // seRender runs after the grid; clicking its "?" earlier races the re-render
  }
  const btn = (page, id) => page.locator(`[data-help="${id}"] .rc-help`);
  const pop = (page, id) => page.locator(`[data-help="${id}"] .rc-pop`);

  test('every card has a real "?" button that toggles a non-modal popover with the expected sections', async ({ page }) => {
    await open(page);
    for (const id of CARDS) {
      await expect(btn(page, id)).toHaveAttribute('aria-expanded', 'false');
      await expect(btn(page, id)).toHaveAccessibleName(/About /);
      await page.mouse.move(600, 20);   // a lingering hover lifts the card above (translateY)
      // force: Playwright's "stable" wait on this button times out about once in 25 runs under CPU load although its box never
      // moves (sampled: one position for 2s in 8 parallel browsers); the real mouse events are still dispatched.
      await btn(page, id).click({ force: true });
      await expect(btn(page, id)).toHaveAttribute('aria-expanded', 'true');
      await expect(pop(page, id)).toBeVisible();
      await expect(btn(page, id)).toHaveAttribute('aria-controls', `up-help-${id}`);
      await btn(page, id).click({ force: true });                    // second click closes
      await expect(pop(page, id)).toHaveCount(0);
      await expect(btn(page, id)).toHaveAttribute('aria-expanded', 'false');
    }
    await btn(page, 'promote-learnings').click();
    for (const h of ['How it happens', 'Why it runs', 'Where learnings come from', 'What it does not do', 'Cost'])
      await expect(pop(page, 'promote-learnings')).toContainText(h, { ignoreCase: true });
    await expect(pop(page, 'promote-learnings')).toContainText('tkt learn');
    await btn(page, 'skill-eval').click();
    for (const h of ['The three stages', 'What we hand to plugin eval', 'Limits'])
      await expect(pop(page, 'skill-eval')).toContainText(h, { ignoreCase: true });
    await expect(pop(page, 'promote-learnings')).toHaveCount(0);      // opening another closes the first
  });

  test('Escape and an outside click close it; a click inside does not', async ({ page }) => {
    await open(page);
    await btn(page, 'context-check').click();
    await pop(page, 'context-check').locator('.rc-pop-lead').click();
    await expect(pop(page, 'context-check')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(pop(page, 'context-check')).toHaveCount(0);
    await btn(page, 'context-check').click();
    await page.locator('.up-h1').click();
    await expect(pop(page, 'context-check')).toHaveCount(0);
    await btn(page, 'context-check').click();
    await pop(page, 'context-check').getByRole('button', { name: 'Close' }).click();
    await expect(pop(page, 'context-check')).toHaveCount(0);
  });

  test('it is non-modal: another card stays operable and no scrim appears', async ({ page }) => {
    await open(page);
    await btn(page, 'promote-learnings').click();
    await expect(pop(page, 'promote-learnings')).toBeVisible();
    await expect(page.locator('.scrim.show')).toHaveCount(0);
    const sel = page.locator('#up-model-context-check');
    await expect(sel).toBeEnabled();
    await sel.selectOption('claude-sonnet-5');                       // selectOption sends no click, so the popover stays open
    await expect(sel).toHaveValue('claude-sonnet-5');
    await expect(pop(page, 'promote-learnings')).toBeVisible();      // the page was usable while it was open, and it is still open
  });

  test('it survives a card re-render (status polling) while open', async ({ page }) => {
    await open(page);
    await btn(page, 'dead-code-cleanup').click();
    await expect(pop(page, 'dead-code-cleanup')).toBeVisible();
    await page.evaluate(() => upRenderGrid());                       // what the 3s poll does when a run finishes
    await expect(pop(page, 'dead-code-cleanup')).toBeVisible();
    await expect(btn(page, 'dead-code-cleanup')).toHaveAttribute('aria-expanded', 'true');
    await page.evaluate(() => loadUpkeep());                         // project switch / view re-entry path
    await expect(pop(page, 'dead-code-cleanup')).toBeVisible();
    await btn(page, 'skill-eval').click({ force: true });           // and the Skill Eval card's own render path
    await expect(pop(page, 'skill-eval')).toBeVisible();
    await page.evaluate(() => seRender());
    await expect(pop(page, 'skill-eval')).toBeVisible();
    await expect(pop(page, 'dead-code-cleanup')).toHaveCount(0);
  });

  test('Escape and the close button return focus to the "?"; an outside click does not steal focus', async ({ page }) => {
    await open(page);
    await btn(page, 'context-doctor').click({ force: true });
    await page.keyboard.press('Escape');
    await expect(btn(page, 'context-doctor')).toBeFocused();
    await btn(page, 'context-doctor').click({ force: true });
    await pop(page, 'context-doctor').getByRole('button', { name: 'Close' }).click();
    await expect(btn(page, 'context-doctor')).toBeFocused();
    await btn(page, 'context-doctor').click({ force: true });
    await page.locator('#up-model-context-check').focus();
    await page.locator('.up-h1').click();
    await expect(pop(page, 'context-doctor')).toHaveCount(0);
    await expect(btn(page, 'context-doctor')).not.toBeFocused();
  });

  test('the reader\'s scroll position survives a card re-render; a different card starts at the top', async ({ page }) => {
    await open(page);
    await btn(page, 'skill-eval').click({ force: true });
    const body = pop(page, 'skill-eval').locator('.rc-pop-body');
    await body.evaluate(el => { el.scrollTop = 120; });
    await expect.poll(() => body.evaluate(el => el.scrollTop)).toBeGreaterThan(50);
    await page.waitForFunction(() => upHelpScroll > 50);             // the scroll event (async) is what records the position; a real reader's scroll is long done before a re-render
    await page.evaluate(() => seRender());
    await expect.poll(() => pop(page, 'skill-eval').locator('.rc-pop-body').evaluate(el => el.scrollTop)).toBeGreaterThan(50);
    // The Skill Eval popover opens upward over the right-hand cards, so switch via the left column's "?" (not covered).
    await btn(page, 'context-check').click();
    await expect(pop(page, 'context-check')).toBeVisible();
    await expect.poll(() => pop(page, 'context-check').locator('.rc-pop-body').evaluate(el => el.scrollTop)).toBe(0);
    await btn(page, 'skill-eval').click({ force: true });                      // back: it does not resume the old position
    await expect.poll(() => pop(page, 'skill-eval').locator('.rc-pop-body').evaluate(el => el.scrollTop)).toBe(0);
  });

  test('a window resize closes it (placement is computed once)', async ({ page }) => {
    await open(page);
    await btn(page, 'context-check').click({ force: true });
    await expect(pop(page, 'context-check')).toBeVisible();
    await page.setViewportSize({ width: 1000, height: 800 });
    await expect(pop(page, 'context-check')).toHaveCount(0);
  });

  test('the popover text says what is true: allowed git/wc, tkt learn/learnings-sweep run automatically, honest Skill Eval limits, chips', async ({ page }) => {
    await open(page);
    await btn(page, 'context-check').click({ force: true });
    const cc = pop(page, 'context-check');
    await expect(cc).toContainText('runs no arbitrary shell commands');
    await expect(cc).toContainText('read-only git and wc');
    await expect(cc).not.toContainText('does not run shell commands');
    await expect(cc).toContainText('many tool turns');
    await expect(cc.locator('.rc-pop-fact', { hasText: 'Reads' })).toContainText('project and global');
    await expect(cc.locator('.rc-pop-fact', { hasText: 'Writes' })).toContainText('one report');
    await btn(page, 'promote-learnings').click({ force: true });
    await expect(pop(page, 'promote-learnings')).toContainText('the sprint agent runs this itself at close');
    await expect(pop(page, 'promote-learnings')).toContainText('also automatic, right after');   // learnings-sweep, not just tkt learn
    await btn(page, 'skill-eval').click({ force: true });
    const se = pop(page, 'skill-eval');
    await expect(se).toContainText('for most cases, a check that the skill actually fired');
    await expect(se).toContainText('needs your explicit OK');
    await expect(se).toContainText('may never fire');
    await expect(se.locator('.rc-pop-fact', { hasText: 'Cost' })).toContainText('$3');
    await expect(se.locator('.rc-pop-fact', { hasText: 'Writes' })).toContainText('skillEvalRuns.json');
  });

  for (const width of [1100, 600]) {
    test(`the popover stays inside the window and clear of the sidebar at ${width}px`, async ({ page }) => {
      await open(page, width);
      for (const id of CARDS) {
        await btn(page, id).click();
        const b = await pop(page, id).boundingBox();
        const main = await page.locator('.main').boundingBox();
        expect(b.x).toBeGreaterThanOrEqual(main.x - 1);
        expect(b.x + b.width).toBeLessThanOrEqual(main.x + main.width + 1);
        expect(b.y).toBeGreaterThanOrEqual(-1);
        expect(b.y + b.height).toBeLessThanOrEqual(900 + 1);   // flips upward / shrinks instead of running off the bottom
        await btn(page, id).click();
      }
    });
  }
});

// .serial: these tests mutate the shared, board-wide model-tiers.json — never
// safe to interleave with each other (a concurrent restore can stomp on a
// sibling test's in-flight edit and leave the file in a state neither test
// wrote).
// t-294b: model cards are read-only until Edit; Save/Cancel are explicit. The registry API is
// stubbed so these tests never write the real (possibly user-local) model-tiers.json.
test.describe('canon-cockpit Admin > Model Tiers editing (t-294b)', () => {
  const FIXTURE = {
    defaults: { eval: { anthropic: 'm-sonnet', openai: 'o-luna' }, light: { anthropic: 'm-haiku', openai: 'o-luna' } },
    models: {
      anthropic: [
        { id: 'm-sonnet', name: 'Sonnet Test', alias: 'sonnet', desc: 'Balanced.', reasoning: [], input_price: 3, output_price: 15 },
        { id: 'm-haiku', name: 'Haiku Test', alias: 'haiku', desc: 'Fast.', reasoning: [], input_price: 1, output_price: 5 },
      ],
      openai: [{ id: 'o-luna', name: 'Luna Test', desc: '', reasoning: [], input_price: 1, output_price: 2 }],
    },
  };
  async function openModelTiers(page) {
    const posts = [];
    let current = JSON.parse(JSON.stringify(FIXTURE));
    await page.route('**/api/admin/model-tiers', async route => {
      if (route.request().method() === 'POST') {
        current = route.request().postDataJSON();
        posts.push(current);
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(current) });
    });
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-admin').click();
    await expect(page.locator('.mt-card[data-id="m-sonnet"]')).toBeVisible();
    return posts;
  }
  const card = (page, id) => page.locator(`.mt-card[data-id="${id}"]`);

  test('cards are read-only: nothing is editable and clicking/typing saves nothing (t-294b)', async ({ page }) => {
    const posts = await openModelTiers(page);
    expect(await page.locator('.mt-grid [contenteditable]').count()).toBe(0);
    await card(page, 'm-sonnet').locator('.mt-card-desc').click();
    await page.keyboard.type('df');
    await page.locator('#view-admin').click({ position: { x: 5, y: 5 } });
    await expect(card(page, 'm-sonnet').locator('.mt-card-desc')).toHaveText('Balanced.');
    expect(posts.length).toBe(0);
  });

  test('Edit then Cancel or Escape restores the values and sends nothing; only one card edits at a time (t-294b)', async ({ page }) => {
    const posts = await openModelTiers(page);
    await card(page, 'm-sonnet').locator('.mt-edit').click();
    const c = card(page, 'm-sonnet');
    await expect(c).toHaveClass(/editing/);
    for (const [field, label] of [['name', 'Name'], ['desc', 'Description'], ['alias', 'Gate-model alias'], ['input_price', 'Input $/MTok'], ['output_price', 'Output $/MTok']]) {
      await expect(c.getByLabel(label)).toHaveAttribute('data-field', field);
    }
    await expect(card(page, 'm-haiku').locator('.mt-edit')).toBeDisabled();
    await c.getByLabel('Name').fill('Changed');
    await c.locator('.mt-cancel').click();
    await expect(card(page, 'm-sonnet').locator('.mt-card-name')).toHaveText('Sonnet Test');
    await card(page, 'm-sonnet').locator('.mt-edit').click();
    await card(page, 'm-sonnet').getByLabel('Name').fill('Changed again');
    await page.keyboard.press('Escape');
    await expect(card(page, 'm-sonnet').locator('.mt-card-name')).toHaveText('Sonnet Test');
    await expect(card(page, 'm-haiku').locator('.mt-edit')).toBeEnabled();
    expect(posts.length).toBe(0);
  });

  test('Save (or Enter) sends one request with the new values and shows them read-only (t-294b)', async ({ page }) => {
    const posts = await openModelTiers(page);
    await card(page, 'm-sonnet').locator('.mt-edit').click();
    const c = card(page, 'm-sonnet');
    await c.getByLabel('Name').fill('Sonnet Renamed');
    await c.getByLabel('Description').fill('New desc');
    await c.getByLabel('Gate-model alias').fill('sonnet-x');
    await c.getByLabel('Input $/MTok').fill('2.5');
    await c.getByLabel('Output $/MTok').fill('12');
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      await c.screenshot({ path: path.join(PROJECT_ROOT, '.tickets', 't-294b', 'visuals', `edit-card-${theme}.png`) });
    }
    await c.locator('.mt-save').click();
    await expect(card(page, 'm-sonnet').locator('.mt-card-name')).toHaveText('Sonnet Renamed');
    await expect(card(page, 'm-sonnet')).not.toHaveClass(/editing/);
    expect(posts.length).toBe(1);
    expect(posts[0].models.anthropic[0]).toMatchObject({ id: 'm-sonnet', name: 'Sonnet Renamed', desc: 'New desc', alias: 'sonnet-x', input_price: 2.5, output_price: 12 });
    await card(page, 'm-haiku').locator('.mt-edit').click();
    await card(page, 'm-haiku').getByLabel('Description').fill('Enter saves');
    await page.keyboard.press('Enter');
    await expect(card(page, 'm-haiku').locator('.mt-card-desc')).toHaveText('Enter saves');
    expect(posts.length).toBe(2);
  });

  test('invalid name, alias or price blocks Save with a message and sends nothing (t-294b)', async ({ page }) => {
    const posts = await openModelTiers(page);
    await card(page, 'm-sonnet').locator('.mt-edit').click();
    const c = card(page, 'm-sonnet');
    const cases = [
      ['Name', '', 'Name can’t be empty.'],
      ['Gate-model alias', 'bad alias!', 'Alias may only contain letters, digits, "." "_" "-".'],
      ['Input $/MTok', '-1', 'Prices must be numbers of 0 or more.'],
    ];
    for (const [label, value, msg] of cases) {
      const input = c.getByLabel(label);
      const before = await input.inputValue();
      await input.fill(value);
      await c.locator('.mt-save').click();
      await expect(c.locator('.mt-card-err')).toHaveText(msg);
      await expect(c).toHaveClass(/editing/);
      await input.fill(before);
    }
    expect(posts.length).toBe(0);
  });

  test('+ Add creates the model with a seeded alias and opens it in edit mode (t-294b)', async ({ page }) => {
    const posts = await openModelTiers(page);
    await page.locator('.mt-add-card').click();
    const editing = page.locator('.mt-card.editing');
    await expect(editing).toHaveCount(1);
    await expect(editing.getByLabel('Name')).toHaveValue('New Model');
    await expect(editing.getByLabel('Gate-model alias')).not.toHaveValue('');
    await expect(editing.getByLabel('Name')).toBeFocused();
    expect(posts.length).toBe(1);
    expect(posts[0].models.anthropic.some(m => m.name === 'New Model' && m.alias)).toBe(true);
  });

  test('the board and cockpit pages declare an icon, so nothing requests /favicon.ico (t-294b)', async ({ page }) => {
    const favicon = [];
    page.on('request', r => { if (new URL(r.url()).pathname === '/favicon.ico') favicon.push(r.url()); });
    for (const url of [BASE, BASE + '/cockpit']) {
      await page.goto(url);
      await page.waitForLoadState('networkidle');
      const href = await page.locator('link[rel="icon"]').getAttribute('href');
      expect(href).toMatch(/^data:image\/svg\+xml,/);
      const size = await page.evaluate(h => new Promise(res => { const i = new Image(); i.onload = () => res([i.naturalWidth, i.naturalHeight]); i.onerror = () => res(null); i.src = h; }), href);
      expect(size).not.toBeNull();                  // the data URI is a valid, decodable SVG
    }
    expect(favicon).toEqual([]);
  });

  test('Admin default pickers have a solid themed background, not transparent (Edge popup source) (t-294b)', async ({ page }) => {
    await openModelTiers(page);
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      const [sel, box] = await page.locator('#mt-default-eval .mt-picker').first().evaluate(p =>
        [getComputedStyle(p.querySelector('select')).backgroundColor, getComputedStyle(p).backgroundColor]);
      expect(sel).toBe(box);
      expect(sel).not.toBe('rgba(0, 0, 0, 0)');
    }
  });

  test('board select popups follow the theme (t-294b)', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    for (const [theme, want] of [['dark', 'dark'], ['light', 'light']]) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      const got = await page.evaluate(() => {
        const probe = document.createElement('span'); document.body.appendChild(probe);
        probe.style.background = 'var(--surface)'; probe.style.color = 'var(--text)';
        const s = document.createElement('select'); const o = document.createElement('option'); s.appendChild(o); document.body.appendChild(s);
        const r = { scheme: getComputedStyle(document.documentElement).colorScheme,
          optBg: getComputedStyle(o).backgroundColor, optColor: getComputedStyle(o).color,
          surface: getComputedStyle(probe).backgroundColor, text: getComputedStyle(probe).color };
        s.remove(); probe.remove(); return r;
      });
      expect(got.scheme).toBe(want);
      expect(got.optBg).toBe(got.surface);
      expect(got.optColor).toBe(got.text);
    }
  });
});

test.describe.serial('canon-cockpit Admin > Model Tiers (t-7e36)', () => {
  test('Model Tiers shows provider tabs, default pickers, seeded Anthropic cards, and the OpenAI-inert banner', async ({ page }) => {
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-admin').click();
    await expect(page.locator('#view-admin')).toHaveClass(/active/);
    await expect(page.locator('.mt-banner')).toContainText('not yet dispatched');
    await expect(page.locator('.mt-banner')).toContainText('OpenAI');
    // default pickers: one row per tier, each offering both providers
    await expect(page.locator('#mt-default-eval .mt-picker')).toHaveCount(2);
    await expect(page.locator('#mt-default-light .mt-picker')).toHaveCount(2);
    // Anthropic tab active by default with the 4 seeded models
    await expect(page.locator('.mt-tab.active')).toContainText('Anthropic');
    await expect(page.locator('.mt-grid .mt-card .mt-card-name')).toContainText(['Claude Fable 5.1', 'Claude Opus 5.5', 'Claude Sonnet 5', 'Claude Haiku 4.5']);
    // switching to OpenAI shows its 3 seeded models
    await page.locator('.mt-tab', { hasText: 'OpenAI' }).click();
    await expect(page.locator('.mt-grid .mt-card .mt-card-name')).toContainText(['GPT-6 Astra', 'GPT-6 Sol', 'GPT-6 Luna']);
  });

  test('Review & Eval card states that gate effort comes from the agent definitions (t-c774)', async ({ page }) => {
    await page.goto(BASE + '/cockpit');
    await page.waitForLoadState('networkidle');
    await page.locator('#nav-admin').click();
    const card = page.locator('.mt-default-card', { has: page.locator('#mt-default-eval') });
    const note = card.locator('#mt-effort-note');
    await expect(note).toBeVisible();
    await expect(note).toContainText('Effort: high');
    await expect(note).toContainText('agents/canon-reviewer.md');
    // Rendered under the model pickers, inside the Review & Eval card only.
    const [pickBox, noteBox] = [await card.locator('#mt-default-eval').boundingBox(), await note.boundingBox()];
    expect(noteBox.y).toBeGreaterThanOrEqual(pickBox.y + pickBox.height);
    await expect(page.locator('.mt-default-card', { has: page.locator('#mt-default-light') }).locator('#mt-effort-note')).toHaveCount(0);
    for (const theme of ['dark', 'light']) {
      await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
      await card.screenshot({ path: test.info().outputPath(`review-eval-card-${theme}.png`) });
    }
  });

  // Restore against the canonical file on disk, not a live GET snapshot — a
  // snapshot could itself be dirty (e.g. a prior interrupted run's leftover),
  // which would perpetuate corruption across runs instead of healing it.
  const MODEL_TIERS_PATH = path.join(PROJECT_ROOT, 'tools', 'sprint-check-app', 'model-tiers.json');
  function readCanonicalModelTiers() {
    return fs.readFileSync(MODEL_TIERS_PATH, 'utf8');
  }
  async function restoreModelTiers(page, canonical) {
    await page.request.post(BASE + '/api/admin/model-tiers', { data: JSON.parse(canonical) });
  }

  test('Admin "+ Add" creates a real registry entry with a usable alias reachable from the per-ticket dropdown, and Remove deletes it', async ({ page }) => {
    const canonical = readCanonicalModelTiers();
    try {
      await page.goto(BASE + '/cockpit');
      await page.waitForLoadState('networkidle');
      await page.locator('#nav-admin').click();
      await page.locator('.mt-add-card').click();
      await expect(page.locator('.mt-grid .mt-card')).toHaveCount(5); // 4 seeded + 1 new
      let newAlias;
      await expect.poll(async () => {
        const reg = await (await page.request.get(BASE + '/api/admin/model-tiers')).json();
        const m = reg.models.anthropic.find(m => m.name === 'New Model');
        newAlias = m && m.alias;
        return Boolean(newAlias);
      }).toBe(true); // t-7e36 review finding: the Add button used to omit alias entirely,
                      // so a UI-added model could never reach the per-ticket dropdown below.

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill('t-7e36');
      await page.locator('.card[data-id="t-7e36"]').click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator(`.model-tier-select option[value="${newAlias}"]`)).toHaveText('New Model');

      await page.locator('#board-search').fill('');
      await page.goto(BASE + '/cockpit');
      await page.waitForLoadState('networkidle');
      await page.locator('#nav-admin').click();
      await page.locator('.mt-grid .mt-card', { hasText: 'New Model' }).locator('.danger').click();
      await expect(page.locator('#cconfirm')).toHaveClass(/show/);
      await page.locator('#cc-ok').click(); // confirm the Remove dialog
      await expect(page.locator('.mt-grid .mt-card')).toHaveCount(4);
      await expect.poll(async () => {
        const reg = await (await page.request.get(BASE + '/api/admin/model-tiers')).json();
        return reg.models.anthropic.some(m => m.name === 'New Model');
      }).toBe(false);
    } finally {
      await restoreModelTiers(page, canonical);
    }
  });

  test('editing a saved model persists and sources the per-ticket Gate-model dropdown, not just the hardcoded fallback', async ({ page }) => {
    const id = `t-mtreg-${Date.now()}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);
    const canonical = readCanonicalModelTiers();
    try {
      // Add a model with a stable alias distinct from every hardcoded fallback value
      // (default/fable/opus/sonnet/haiku) directly via the same POST route the UI uses —
      // its later appearance in the per-ticket dropdown can only be explained by a live
      // fetch of the registry, not the JS fallback array.
      const reg = JSON.parse(canonical);
      reg.models.anthropic.push({
        id: 'probe-model-zz', alias: 'probe-alias-zz', name: 'Registry Sourcing Probe',
        desc: 'test fixture', reasoning: [], input_price: 1, output_price: 1,
      });
      const postRes = await page.request.post(BASE + '/api/admin/model-tiers', { data: reg });
      expect(postRes.ok()).toBeTruthy();

      // GET round-trips the edit — proves persistence, not just an in-memory echo.
      const after = await (await page.request.get(BASE + '/api/admin/model-tiers')).json();
      expect(after.models.anthropic.find(m => m.id === 'probe-model-zz').name).toBe('Registry Sourcing Probe');

      // Admin UI renders the persisted edit.
      await page.goto(BASE + '/cockpit');
      await page.waitForLoadState('networkidle');
      await page.locator('#nav-admin').click();
      await expect(page.locator('.mt-grid .mt-card', { hasText: 'Registry Sourcing Probe' })).toBeVisible();

      // Per-ticket Gate-model dropdown lists it too.
      fs.mkdirSync(ticketDir, { recursive: true });
      fs.writeFileSync(path.join(ticketDir, 'ticket.md'), [
        '---', `id: ${id}`, 'status: in_progress', 'type: task', 'priority: 2',
        'created: 2026-09-23T00:00:00Z', '---', '', '# Model registry sourcing test', '',
      ].join('\n'));
      fs.writeFileSync(path.join(ticketDir, 'plan.md'), [
        '# Plan', '', '## Sign-off', 'Tier: normal | Risk: test', '', '- [x] Plan approved', '',
        '## Approach', 'n/a', '',
        // injectSectionJumps (and with it the Sign-off model-tier <select>) only
        // renders once the doc has >=2 "## " headings — a single-heading plan.md
        // silently renders no dropdown at all (t-7e36 debugging).
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      // The dropdown's option list is populated by an async fetch fired at page
      // load, independent of the DOM interactions above — poll rather than assert
      // once, so a slow-to-resolve fetch isn't mistaken for a missing option.
      await expect.poll(() =>
        page.locator('.model-tier-select option[value="probe-alias-zz"]').count()
      ).toBe(1);
      await expect(page.locator('.model-tier-select option[value="probe-alias-zz"]')).toHaveText('Registry Sourcing Probe');
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
      await restoreModelTiers(page, canonical);
    }
  });
});

test.describe('branch divergence badge (t-6328)', () => {
  test('a ticket with branch_divergence shows a card badge + modal footer note; a normal ticket shows neither; hostile branch names stay inert text', async ({ page }) => {
    const stamp = Date.now();
    const divId = `t-brdv-${stamp}`;
    const okId = `t-brok-${stamp}`;
    const evilId = `t-brev-${stamp}`;
    try {
      for (const id of [divId, okId, evilId]) {
        const dir = path.join(PROJECT_ROOT, '.tickets', id);
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, 'ticket.md'), [
          '---', `id: ${id}`, 'status: open', 'type: task', 'priority: 2',
          'created: 2026-09-23T00:00:00Z', '---', '', `# Divergence ${id}`, '',
        ].join('\n'));
      }
      // Real /api/tickets, with branch_divergence injected on two tickets.
      await page.route('**/api/tickets*', async route => {
        if (route.request().method() !== 'GET') return route.continue();
        const res = await route.fetch();
        const tickets = await res.json();
        for (const t of tickets) {
          if (t.id === divId) t.branch_divergence = { branch: 'sprint/t-91mc', status: 'closed', where: 'branch', merged: false };
          if (t.id === evilId) t.branch_divergence = { branch: '<img src=x onerror="window.__pwn=1"> x" onmouseover="window.__pwn=1" data-y="', status: 'closed', where: 'worktree', merged: true };
        }
        await route.fulfill({ response: res, json: tickets });
      });
      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(divId);
      const divCard = page.locator(`.card[data-id="${divId}"]`);
      await expect(divCard.locator('.card-diverge')).toHaveText('closed on sprint/t-91mc');
      await divCard.click();
      await expect(page.locator('#m-diverge')).toBeVisible();
      await expect(page.locator('#m-diverge')).toHaveText("Showing this checkout's copy (open) — closed on sprint/t-91mc, not merged.");
      await page.keyboard.press('Escape');

      await page.locator('#board-search').fill(okId);
      const okCard = page.locator(`.card[data-id="${okId}"]`);
      await expect(okCard).toBeVisible();
      await expect(okCard.locator('.card-diverge')).toHaveCount(0);
      await okCard.click();
      await expect(page.locator('#m-diverge')).toBeHidden();
      await page.keyboard.press('Escape');

      await page.locator('#board-search').fill(evilId);
      const evilCard = page.locator(`.card[data-id="${evilId}"]`);
      await expect(evilCard.locator('.card-diverge')).toContainText('<img src=x onerror=');
      await expect(evilCard.locator('.card-diverge img')).toHaveCount(0);
      // Attribute breakout: a `"` in the branch name must not escape the title="…" attribute.
      const badge = evilCard.locator('.card-diverge');
      expect(await badge.getAttribute('onmouseover')).toBeNull();
      expect(await badge.getAttribute('data-y')).toBeNull();
      expect(await badge.getAttribute('title')).toContain('onmouseover="window.__pwn=1"');
      await badge.hover();
      await evilCard.click();
      await expect(page.locator('#m-diverge')).toContainText('in worktree <img src=x');
      await expect(page.locator('#m-diverge')).toContainText('(branch merged)');
      expect(await page.evaluate(() => window.__pwn)).toBeUndefined();
    } finally {
      for (const id of [divId, okId, evilId]) fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
    }
  });
});

test.describe('project-scoped ticket assets (t-7d83)', () => {
  test('end to end: a plan image in a second project loads in that project\'s Cockpit tab (was a 404)', async ({ page }) => {
    const os = require('os');
    const net = require('net');
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'canon-t7d83-'));
    const defaultRoot = path.join(root, 'default');
    const otherRoot = path.join(root, 'other');
    const canonHome = path.join(root, 'canon-home');
    const id = 't-pj01';
    let proc;
    try {
      fs.mkdirSync(path.join(defaultRoot, '.tickets'), { recursive: true });
      fs.mkdirSync(path.join(otherRoot, '.git'), { recursive: true });
      const dir = path.join(otherRoot, '.tickets', id);
      fs.mkdirSync(path.join(dir, 'visuals'), { recursive: true });
      fs.writeFileSync(path.join(dir, 'visuals', 'pic.png'), Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64'));
      fs.writeFileSync(path.join(dir, 'ticket.md'), ['---', `id: ${id}`, 'status: in_progress', 'type: task', 'priority: 2',
        'created: 2026-09-23T00:00:00Z', '---', '', '# Other project ticket', ''].join('\n'));
      fs.writeFileSync(path.join(dir, 'plan.md'), ['# Plan', '', '## Sign-off', '- [x] Plan approved', '', '## Approach',
        'See:', '', '![pic](visuals/pic.png)', ''].join('\n'));

      const port = await new Promise(resolve => {
        const srv = net.createServer();
        srv.listen(0, '127.0.0.1', () => { const p = srv.address().port; srv.close(() => resolve(p)); });
      });
      proc = spawn('python3', [path.join(__dirname, '..', 'tools', 'sprint-check-app', 'server.py'), String(port)], {
        cwd: defaultRoot, env: { ...process.env, SPRINT_CHECK_ROOT: defaultRoot, CANON_HOME: canonHome }, stdio: 'ignore',
      });
      const base = `http://127.0.0.1:${port}`;
      await expect.poll(async () => { try { return (await page.request.get(`${base}/api/tickets`)).status(); } catch { return 0; } }, { timeout: 8000 }).toBe(200);
      const add = await page.request.post(`${base}/api/projects`, { headers: { Origin: 'http://localhost' }, data: { path: otherRoot, description: 't7d83' } });
      expect(add.ok()).toBeTruthy();
      const pid = (await (await page.request.get(`${base}/api/projects`)).json()).find(e => e.path.endsWith('other')).id;

      await page.goto(`${base}/?project=${pid}`);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      const img = page.locator('#m-body img.doc-visual-img');
      await expect(img).toBeVisible();
      await expect(img).toHaveAttribute('src', `/api/ticket-image/${id}/visuals/pic.png?project=${pid}`);
      await expect.poll(() => img.evaluate(el => el.naturalWidth)).toBeGreaterThan(0);
    } finally {
      if (proc) proc.kill();
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  test('in a Cockpit project tab the .feature fetch and image URLs carry ?project=; the standalone board is unchanged', async ({ page }) => {
    const seen = [];
    page.on('request', req => { if (/\/api\/ticket-feature\//.test(req.url())) seen.push(req.url()); });

    // Embedded project tab: board loaded as /?project=<id> (unknown id is fine — we only inspect URLs).
    await page.goto(BASE + '/?project=zz9');
    await page.evaluate(() => fetch('/api/ticket-feature/t-abcd/features/x.feature').catch(() => {}));
    await expect.poll(() => seen.length).toBeGreaterThan(0);
    expect(seen[0]).toContain('project=zz9');
    const scoped = await page.evaluate(() => ({
      rel: resolveMockupSrc('visuals/a b.png', 't-abcd'),
      abs: resolveMockupSrc('https://example.com/x.png', 't-abcd'),
      root: resolveMockupSrc('/meta/x.png', 't-abcd'),
    }));
    expect(scoped.rel).toBe('/api/ticket-image/t-abcd/visuals/a%20b.png?project=zz9');
    expect(scoped.abs).toBe('https://example.com/x.png');
    expect(scoped.root).toBe('/meta/x.png');

    // Project ids are URL-encoded, not trusted.
    await page.goto(BASE + '/?project=' + encodeURIComponent('a&b=c d'));
    expect(await page.evaluate(() => resolveMockupSrc('v/x.png', 't-abcd')))
      .toBe('/api/ticket-image/t-abcd/v/x.png?project=a%26b%3Dc%20d');

    // Standalone board: no param anywhere.
    seen.length = 0;
    await page.goto(BASE + '/');
    await page.evaluate(() => fetch('/api/ticket-feature/t-abcd/features/x.feature').catch(() => {}));
    await expect.poll(() => seen.length).toBeGreaterThan(0);
    expect(seen[0]).not.toContain('project=');
    expect(await page.evaluate(() => resolveMockupSrc('visuals/a.png', 't-abcd')))
      .toBe('/api/ticket-image/t-abcd/visuals/a.png');
  });
});
