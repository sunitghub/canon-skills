// meta/record-demo.mjs — reproducible recorder for the doc-editor demo GIF.
// Drives the real sprint-check board through the in-place edit flow and renders
// meta/doc-editing.gif. Author-only; never shipped to users (root ships bin/ only).
//
// Usage:  cd meta && npm install && npm run record
// Needs:  python3 (server), ffmpeg (gif encode), playwright (devDependency).

import { chromium } from 'playwright';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SERVER = path.join(ROOT, 'tools', 'sprint-check-app', 'server.py');
const OUT_GIF = path.join(HERE, 'doc-editing.gif');
const REC_DIR = path.join(HERE, '.rec');

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

function seedFixture() {
  const dir = mkdtempSync(path.join(tmpdir(), 'canon-demo-'));
  const tdir = path.join(dir, '.tickets', 't-oauth');
  mkdirSync(tdir, { recursive: true });
  writeFileSync(path.join(tdir, 'ticket.md'),
    '---\nid: t-oauth\ntitle: Add OAuth login\nstatus: in_progress\n' +
    'type: feature\npriority: 1\ncreated: 2026-06-03\n---\n' +
    '# Add OAuth login\n\nLet users sign in with Google.\n');
  writeFileSync(path.join(tdir, 'acceptance.md'),
    '---\nid: t-oauth\n---\n# Acceptance\n\n' +
    `Ticket: \`t-oauth\`\n\n## Criteria\n\n## Test Plan\n`);
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
  rmSync(REC_DIR, { recursive: true, force: true });
  const fixture = seedFixture();
  const port = await freePort();

  const server = spawn('python3', [SERVER, String(port)], {
    env: { ...process.env, SPRINT_CHECK_ROOT: fixture },
    stdio: 'ignore',
  });

  let box = null;
  try {
    await waitForServer(port);

    const browser = await chromium.launch();
    const context = await browser.newContext({
      viewport: { width: 1180, height: 720 },
      deviceScaleFactor: 2,
      recordVideo: { dir: REC_DIR, size: { width: 1180, height: 720 } },
    });
    const page = await context.newPage();
    page.on('dialog', (d) => d.dismiss().catch(() => {})); // safety: never hang on a validation alert

    await page.goto(`http://127.0.0.1:${port}/`);
    await page.waitForSelector('.card[data-id="t-oauth"]');
    await sleep(500);

    await page.click('.card[data-id="t-oauth"]');
    await page.waitForSelector('#btn-edit-doc', { state: 'visible' });
    await sleep(350);

    // open the Acceptance doc, then enter edit mode
    await page.locator('.doc-tab', { hasText: 'Acceptance' }).click();
    await sleep(350);
    await page.click('#btn-edit-doc');
    await page.waitForSelector('#m-edit-area', { state: 'visible' });
    await page.waitForFunction(() => {
      const el = document.getElementById('m-edit-area');
      return el && el.value.includes('## Criteria');
    });
    await sleep(300);

    // capture the modal box now (tallest, in edit mode) to crop the final GIF to it
    box = await page.locator('#modal').boundingBox();

    // cursor to end, then drive the toolbar — append keeps required headings intact
    await page.$eval('#m-edit-area', (el) => {
      el.focus();
      el.value = el.value.replace(/\s+$/, '') + '\n\n';
      el.selectionStart = el.selectionEnd = el.value.length;
    });

    const steps = [
      ['checkbox', 'Server verifies the Google ID token signature'],
      ['checkbox', 'Session cookie is HttpOnly and Secure'],
      ['heading', 'Launch checklist'],
      ['checkbox', 'npm badge resolves and '],
      ['code', 'npx canon-skills'],
    ];
    for (const [kind, text] of steps) {
      await page.click(`.editor-tool[data-insert="${kind}"]`);
      await sleep(300);
      if (text) await page.keyboard.type(text, { delay: 38 });
      await sleep(380);
    }
    await sleep(550);

    await page.click('#act-save');
    await sleep(700);

    await context.close(); // flush the video to disk
    await browser.close();
  } finally {
    server.kill();
  }

  const webm = readdirSync(REC_DIR).find((f) => f.endsWith('.webm'));
  if (!webm) throw new Error('no video recorded');
  const src = path.join(REC_DIR, webm);
  const palette = path.join(REC_DIR, 'palette.png');

  // crop to the modal (legibility + size), then scale to a fixed README width
  let crop = '';
  if (box) {
    const pad = 16, VW = 1180, VH = 720;
    const cx = Math.max(0, Math.floor(box.x - pad));
    const cy = Math.max(0, Math.floor(box.y - pad));
    let cw = Math.min(VW - cx, Math.ceil(box.width + pad * 2)); cw -= cw % 2;
    let ch = Math.min(VH - cy, Math.ceil(box.height + pad * 2)); ch -= ch % 2;
    crop = `crop=${cw}:${ch}:${cx}:${cy},`;
  }
  const vf = `${crop}fps=10,scale=760:-1:flags=lanczos`;

  const p = spawnSync('ffmpeg', ['-y', '-i', src, '-vf', `${vf},palettegen=stats_mode=diff:max_colors=64`, palette], { stdio: 'inherit' });
  if (p.status !== 0) throw new Error('ffmpeg palettegen failed');
  const g = spawnSync('ffmpeg', ['-y', '-i', src, '-i', palette, '-lavfi', `${vf} [x]; [x][1:v] paletteuse=dither=none`, OUT_GIF], { stdio: 'inherit' });
  if (g.status !== 0) throw new Error('ffmpeg paletteuse failed');

  rmSync(fixture, { recursive: true, force: true });
  console.log('wrote', OUT_GIF);
}

main().catch((e) => { console.error(e); process.exit(1); });
