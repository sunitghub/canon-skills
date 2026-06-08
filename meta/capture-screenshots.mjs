// meta/capture-screenshots.mjs — reproducible sprint-check screenshot capture.
// Drives sprint-check against a temporary dummy repo and refreshes tracked PNGs
// in meta/screenshots/. Author-only; root package ships bin/ only.
//
// Usage: cd meta && npm install && npm run capture:screenshots
// Needs: python3 and playwright (devDependency).

import { chromium } from 'playwright';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SERVER = path.join(ROOT, 'tools', 'sprint-check-app', 'server.py');
const OUT_DIR = path.join(HERE, 'screenshots');
const VIEWPORT = { width: 1180, height: 720 };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
    s.on('error', reject);
  });
}

function run(cmd, args, cwd) {
  const result = spawnSync(cmd, args, { cwd, stdio: 'ignore' });
  if (result.status !== 0) throw new Error(`${cmd} ${args.join(' ')} failed`);
}

function writeTicket(root, id, status, type, priority, title, body, acceptance, plan) {
  const dir = path.join(root, '.tickets', id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, 'ticket.md'),
    `---\nid: ${id}\ntitle: ${title}\nstatus: ${status}\n` +
    `type: ${type}\npriority: ${priority}\ncreated: 2026-06-08T19:31:58Z\n---\n` +
    `# ${title}\n\n${body}\n`);
  if (acceptance) writeFileSync(path.join(dir, 'acceptance.md'), acceptance);
  if (plan) writeFileSync(path.join(dir, 'plan.md'), plan);
}

function seedFixture() {
  const dir = mkdtempSync(path.join(tmpdir(), 'canon-screenshots-'));
  mkdirSync(path.join(dir, '.tickets'), { recursive: true });
  writeFileSync(path.join(dir, 'HANDOFF.md'),
    '# Handoff\n\n## Current Focus\n\nPolishing sprint-check ticket cards and checklist rendering.\n');

  const acceptance =
`# Acceptance

Ticket: \`t-4e5d\`

## Criteria
- [ ] Unchecked checklist items sort above completed items.
- [ ] Open checklist rows use a distinct accent.
- [x] Ticket detail cards use tighter vertical spacing.
- [x] Markdown bullets render with normal indentation.

## Test Plan
- [ ] Browser check opens Acceptance with open items first.
- [x] npm test

## QA Sign-off
- [x] Visual review passed in dark mode.
`;
  const plan =
`# Plan

Ticket: \`t-4e5d\`

## Approach
Tune read-mode card spacing, render bullets with explicit marker/content structure, and highlight open checklist items.

## Decisions
### Keep the polish CSS-only where possible
The complaint is visual hierarchy, not modal behavior.
`;
  const placeholderPlan =
`# Plan

Ticket: \`t-5j3d\`

## Approach
How will we implement it?

## Decisions
### [Decision title]
- **Choice:**
- **Why:**
- **Alternatives considered:**
`;

  writeTicket(dir, 't-4e5d', 'in_progress', 'task', 2,
    'Polish sprint-check ticket info card',
    'Improve the ticket modal read-mode hierarchy and checklist readability.',
    acceptance,
    plan);
  writeTicket(dir, 't-2510', 'closed', 'task', 2,
    'Build interactive README-linked demo tour',
    'Turn the README proof into a local, inspectable demo.',
    acceptance.replaceAll('t-4e5d', 't-2510'),
    plan.replaceAll('t-4e5d', 't-2510'));
  writeTicket(dir, 't-9k2a', 'open', 'feature', 1,
    'Add animated README clips',
    'Record short clips for board, ticket detail, doc editing, and commit context.',
    acceptance.replaceAll('t-4e5d', 't-9k2a'),
    plan.replaceAll('t-4e5d', 't-9k2a'));
  writeTicket(dir, 't-5j3d', 'open', 'task', 3,
    'Add skill usage logging to skills.sh',
    'Track skill add/refresh usage locally without adding external services.',
    acceptance.replaceAll('t-4e5d', 't-5j3d'),
    placeholderPlan);
  writeTicket(dir, 't-1q8p', 'cancelled', 'chore', 3,
    'Prototype hosted dashboard',
    'Dropped in favor of local-first sprint-check.',
    null,
    null);

  run('git', ['init'], dir);
  run('git', ['config', 'user.name', 'Canon Demo'], dir);
  run('git', ['config', 'user.email', 'demo@canon.local'], dir);
  run('git', ['add', '.'], dir);
  run('git', ['commit', '-m', 't-4e5d style: polish ticket info card'], dir);
  writeFileSync(path.join(dir, 'README.md'), '# canon demo\n\nFresh sprint-check screenshots.\n');
  run('git', ['add', 'README.md'], dir);
  run('git', ['commit', '-m', 't-2510 docs: add README demo tour'], dir);

  return dir;
}

async function waitForServer(port, tries = 50) {
  for (let i = 0; i < tries; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/api/git`)).ok) return; } catch {}
    await sleep(100);
  }
  throw new Error('server did not start');
}

async function main() {
  const fixture = seedFixture();
  const port = await freePort();
  const server = spawn('python3', [SERVER, String(port)], {
    env: { ...process.env, SPRINT_CHECK_ROOT: fixture },
    stdio: 'ignore',
  });

  try {
    await waitForServer(port);
    const browser = await chromium.launch();
    const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 2 });
    await context.addInitScript(() => localStorage.setItem('sprint-check-theme', 'dark'));
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.waitForSelector('.card[data-id="t-4e5d"]');
    await sleep(500);

    await page.screenshot({ path: path.join(OUT_DIR, 'board-dark.png'), fullPage: true });
    await page.screenshot({ path: path.join(OUT_DIR, 'sprint-check-board-dark.png'), fullPage: true });

    await page.click('.card[data-id="t-4e5d"]');
    await page.waitForSelector('#modal-overlay.open');
    await sleep(350);
    await page.locator('#modal').screenshot({ path: path.join(OUT_DIR, 'ticket-detail.png') });

    await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
    await sleep(300);
    await page.locator('#modal').screenshot({ path: path.join(OUT_DIR, 'ticket-completeness.png') });

    await page.click('#btn-edit-doc');
    await page.waitForSelector('#m-edit-area', { state: 'visible' });
    await sleep(300);
    await page.locator('#modal').screenshot({ path: path.join(OUT_DIR, 'ticket-doc-editor.png') });

    await page.click('#act-cancel');
    await page.waitForSelector('#m-edit-area', { state: 'hidden' });
    await page.click('#btn-close');
    await page.waitForFunction(() => !document.getElementById('modal-overlay').classList.contains('open'));

    await page.click('.card[data-id="t-5j3d"]');
    await page.waitForSelector('#modal-overlay.open');
    await page.locator('.doc-tab', { hasText: 'Plan' }).click();
    await page.waitForSelector('.acceptance-warning');
    await sleep(300);
    await page.locator('#modal').screenshot({ path: path.join(OUT_DIR, 'plan-incomplete.png') });

    await page.click('#btn-close');
    await page.waitForFunction(() => !document.getElementById('modal-overlay').classList.contains('open'));
    await page.click('.commit-item:first-child');
    await page.waitForSelector('#commit-overlay.open');
    await sleep(400);
    await page.locator('#commit-panel').screenshot({ path: path.join(OUT_DIR, 'commit-detail.png') });

    await browser.close();
  } finally {
    server.kill();
    rmSync(fixture, { recursive: true, force: true });
  }

  console.log('refreshed sprint-check screenshots');
}

main().catch((e) => { console.error(e); process.exit(1); });
