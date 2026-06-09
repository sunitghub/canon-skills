// meta/record-readme-demos.mjs — reproducible recorder for README demo GIFs.
// Drives sprint-check against a temporary dummy repo and writes animated clips
// into meta/screenshots/. Author-only; root package ships bin/ only.
//
// Usage: cd meta && npm install && npm run record:readme
// Needs: python3 (server), ffmpeg (GIF encode), playwright (devDependency).

import { chromium } from 'playwright';
import { spawn, spawnSync } from 'node:child_process';
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  readdirSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SERVER = path.join(ROOT, 'tools', 'sprint-check-app', 'server.py');
const OUT_DIR = path.join(HERE, 'screenshots');
const REC_DIR = path.join(HERE, '.rec-readme');
const VIEWPORT = { width: 1180, height: 720 };
const SCALE_WIDTH = 760;

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
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} failed`);
  }
}

function writeTicket(root, id, status, type, priority, title, body, acceptance, plan) {
  const dir = path.join(root, '.tickets', id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, 'ticket.md'),
    `---\nid: ${id}\ntitle: ${title}\nstatus: ${status}\n` +
    `type: ${type}\npriority: ${priority}\ncreated: 2026-06-08T14:20:00Z\n---\n` +
    `# ${title}\n\n${body}\n`);
  if (acceptance) writeFileSync(path.join(dir, 'acceptance.md'), acceptance);
  if (plan) writeFileSync(path.join(dir, 'plan.md'), plan);
}

function seedFixture() {
  const dir = mkdtempSync(path.join(tmpdir(), 'canon-readme-demo-'));
  mkdirSync(path.join(dir, '.tickets'), { recursive: true });
  writeFileSync(path.join(dir, 'HANDOFF.md'),
    '# Handoff\n\n## Current Focus\n\nBuilding sprint-check demos for the README-linked tour.\n');

  const acceptanceReady =
`# Acceptance

Ticket: \`t-2510\`

## Criteria
- [ ] Open checklist rows render first.
- [ ] Open checklist rows use a distinct accent.
- [x] README exposes an animated Demo panel.
- [x] The tour links stay local.

## Test Plan
- [ ] Verify the README clips load.
- [x] Generate clips with Playwright.
- [x] Run npm test.

## QA
- [x] Visual review passed.
`;
  const planReady =
`# Plan

Ticket: \`t-2510\`

## Approach
Use a lightweight local board and record short clips from real UI flows.

## Decisions
### Keep clips local
Store generated GIFs with the screenshots so README links remain stable.
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

  writeTicket(dir, 't-2510', 'in_progress', 'task', 2,
    'Build interactive README-linked demo tour',
    'Turn the README proof into a local, inspectable demo.',
    acceptanceReady,
    planReady);
  writeTicket(dir, 't-9k2a', 'open', 'feature', 1,
    'Add animated README clips',
    'Record short clips for board, ticket detail, doc editing, and commit context.',
    acceptanceReady.replaceAll('t-2510', 't-9k2a'),
    planReady.replaceAll('t-2510', 't-9k2a'));
  writeTicket(dir, 't-7m4b', 'closed', 'task', 2,
    'Capture sprint-check screenshots',
    'Refresh the static screenshots used by the tour.',
    acceptanceReady.replaceAll('t-2510', 't-7m4b'),
    planReady.replaceAll('t-2510', 't-7m4b'));
  writeTicket(dir, 't-5j3d', 'open', 'task', 3,
    'Add skill usage logging to skills.sh',
    'Track skill add/refresh usage locally without adding external services.',
    acceptanceReady.replaceAll('t-2510', 't-5j3d'),
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
  run('git', ['commit', '-m', 't-2510 docs: add README demo tour'], dir);
  writeFileSync(path.join(dir, 'README.md'), '# canon demo\n\nAnimated clips for sprint-check.\n');
  run('git', ['add', 'README.md'], dir);
  run('git', ['commit', '-m', 't-9k2a docs: add animated README clips'], dir);

  return dir;
}

async function waitForServer(port, tries = 50) {
  for (let i = 0; i < tries; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/api/git`)).ok) return; } catch {}
    await sleep(100);
  }
  throw new Error('server did not start');
}

async function withPage(port, name, action) {
  const clipDir = path.join(REC_DIR, name);
  mkdirSync(clipDir, { recursive: true });
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: 2,
    recordVideo: { dir: clipDir, size: VIEWPORT },
  });
  await context.addInitScript(() => {
    localStorage.setItem('sprint-check-theme', 'dark');
  });
  const page = await context.newPage();
  page.on('dialog', (d) => d.dismiss().catch(() => {}));
  await page.goto(`http://127.0.0.1:${port}/`);
  await page.waitForSelector('.card[data-id="t-2510"]');
  await sleep(500);
  const box = await action(page);
  await sleep(600);
  await context.close();
  await browser.close();
  return { clipDir, box };
}

function cropFilter(box) {
  if (!box) return '';
  const pad = 16;
  const cx = Math.max(0, Math.floor(box.x - pad));
  const cy = Math.max(0, Math.floor(box.y - pad));
  let cw = Math.min(VIEWPORT.width - cx, Math.ceil(box.width + pad * 2)); cw -= cw % 2;
  let ch = Math.min(VIEWPORT.height - cy, Math.ceil(box.height + pad * 2)); ch -= ch % 2;
  return `crop=${cw}:${ch}:${cx}:${cy},`;
}

function encodeGif(name, clipDir, box) {
  const webm = readdirSync(clipDir).find((f) => f.endsWith('.webm'));
  if (!webm) throw new Error(`no video recorded for ${name}`);
  const src = path.join(clipDir, webm);
  const palette = path.join(clipDir, 'palette.png');
  const out = path.join(OUT_DIR, `${name}.gif`);
  const startByName = {
    'ticket-detail-demo': 0.7,
    'doc-editing-demo': 1.0,
    'commit-context-demo': 0.6,
  };
  const trim = startByName[name] ? `trim=start=${startByName[name]},setpts=PTS-STARTPTS,` : '';
  const vf = `${trim}${cropFilter(box)}fps=10,scale=${SCALE_WIDTH}:-1:flags=lanczos`;

  let result = spawnSync('ffmpeg', ['-y', '-i', src, '-vf', `${vf},palettegen=stats_mode=diff:max_colors=64`, palette], { stdio: 'inherit' });
  if (result.status !== 0) throw new Error(`ffmpeg palettegen failed for ${name}`);
  result = spawnSync('ffmpeg', ['-y', '-i', src, '-i', palette, '-lavfi', `${vf} [x]; [x][1:v] paletteuse=dither=none`, out], { stdio: 'inherit' });
  if (result.status !== 0) throw new Error(`ffmpeg paletteuse failed for ${name}`);
  console.log('wrote', out);
}

async function main() {
  rmSync(REC_DIR, { recursive: true, force: true });
  const fixture = seedFixture();
  const port = await freePort();
  const server = spawn('python3', [SERVER, String(port)], {
    env: { ...process.env, SPRINT_CHECK_ROOT: fixture },
    stdio: 'ignore',
  });

  try {
    await waitForServer(port);

    const clips = [];
    clips.push(['board-demo', await withPage(port, 'board-demo', async (page) => {
      await page.click('.ready-indicator[data-id="t-2510"]');
      await sleep(850);
      await page.hover('.card[data-id="t-9k2a"]');
      await sleep(650);
      return page.locator('#app').boundingBox();
    })]);

    clips.push(['ticket-search-demo', await withPage(port, 'ticket-search-demo', async (page) => {
      await page.click('#board-search');
      await sleep(250);
      await page.keyboard.type('plan incomplete', { delay: 55 });
      await sleep(900);
      return page.locator('#app').boundingBox();
    })]);

    clips.push(['ticket-detail-demo', await withPage(port, 'ticket-detail-demo', async (page) => {
      await page.click('.card[data-id="t-2510"]');
      await page.waitForSelector('#modal-overlay.open');
      await sleep(500);
      await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
      await sleep(700);
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await sleep(700);
      return page.locator('#modal').boundingBox();
    })]);

    clips.push(['doc-editing-demo', await withPage(port, 'doc-editing-demo', async (page) => {
      await page.click('.card[data-id="t-2510"]');
      await page.waitForSelector('#btn-edit-doc', { state: 'visible' });
      await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
      await sleep(300);
      await page.click('#btn-edit-doc');
      await page.waitForSelector('#m-edit-area', { state: 'visible' });
      const box = await page.locator('#modal').boundingBox();
      await page.$eval('#m-edit-area', (el) => {
        el.focus();
        el.value = el.value.replace(/\s+$/, '') + '\n\n';
        el.selectionStart = el.selectionEnd = el.value.length;
      });
      for (const text of ['README clips render inline', 'Tour anchors still resolve']) {
        await page.click('.editor-tool[data-insert="checkbox"]');
        await sleep(250);
        await page.keyboard.type(text, { delay: 34 });
        await sleep(350);
      }
      return box;
    })]);

    clips.push(['commit-context-demo', await withPage(port, 'commit-context-demo', async (page) => {
      await page.click('.commit-item:first-child');
      await page.waitForSelector('#commit-overlay.open');
      await sleep(800);
      await page.hover('#co-files');
      await sleep(700);
      return page.locator('#commit-panel').boundingBox();
    })]);

    for (const [name, { clipDir, box }] of clips) {
      encodeGif(name, clipDir, box);
    }
  } finally {
    server.kill();
    rmSync(fixture, { recursive: true, force: true });
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
