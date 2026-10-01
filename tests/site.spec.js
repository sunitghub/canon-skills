// @ts-check
// t-4a1b: rendered checks for the static site under site/. Run: npx playwright test tests/site.spec.js
const { test, expect } = require('@playwright/test');
const path = require('path');
const { pathToFileURL } = require('url');

const SITE = process.env.SITE_DIR || path.join(__dirname, '..', 'site');
const PAGES = ['index.html', 'compare.html', 'learnings.html'];
const urlOf = (f) => pathToFileURL(path.join(SITE, f)).href;

function luminance(rgb) {
  const m = rgb.match(/\d+(\.\d+)?/g) || ['0', '0', '0'];
  const [r, g, b] = m.slice(0, 3).map((v) => Number(v) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

for (const scheme of /** @type {const} */ (['dark', 'light'])) {
  for (const width of [1280, 400]) {
    test.describe(`${scheme} at ${width}px`, () => {
      test.use({ colorScheme: scheme, viewport: { width, height: 900 } });
      for (const file of PAGES) {
        test(`${file} does not scroll sideways`, async ({ page }) => {
          await page.goto(urlOf(file), { waitUntil: 'load' });
          await page.evaluate(() => document.querySelectorAll('img[loading=lazy]').forEach((i) => { /** @type {HTMLImageElement} */ (i).loading = 'eager'; }));
          await page.waitForTimeout(300);
          const w = await page.evaluate(() => document.documentElement.scrollWidth);
          expect(w).toBeLessThanOrEqual(width);
        });
      }
    });
  }
}

test.describe('brand', () => {
  for (const scheme of /** @type {const} */ (['dark', 'light'])) {
    for (const file of PAGES) {
      test(`${file} (${scheme}): the header brand is the cannon in the accent colour, and the favicon is the cannon`, async ({ page }) => {
        await page.emulateMedia({ colorScheme: scheme });
        await page.goto(urlOf(file));
        const info = await page.evaluate(() => {
          const mark = document.querySelector('.brand svg.mk');
          const probe = document.createElement('span');
          probe.style.color = 'var(--accent)';
          document.body.appendChild(probe);
          const accent = getComputedStyle(probe).color;
          probe.remove();
          const icon = document.querySelector('link[rel="icon"]').getAttribute('href');
          return { hasMark: !!mark, color: mark ? getComputedStyle(mark).color : null, accent, icon };
        });
        expect(info.hasMark).toBe(true);
        expect(info.color).toBe(info.accent);
        expect(info.accent).toBe(scheme === 'dark' ? 'rgb(139, 123, 255)' : 'rgb(108, 92, 247)');
        const icon = decodeURIComponent(info.icon);
        expect(icon).toContain('<mask');
        expect(icon).not.toContain('M16 6.5l9.5 9.5');
      });
    }
  }
  test('the hero cannon stays small and sits low, and the page does not scroll sideways', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto(urlOf('index.html'));
    const box = await page.$eval('.hero-mark', (e) => { const r = e.getBoundingClientRect(); return { w: r.width, top: r.top + window.scrollY }; });
    expect(box.w).toBeLessThanOrEqual(620);
    expect(box.top).toBeGreaterThanOrEqual(80);
  });
});

test.describe('home flow', () => {
  test.use({ colorScheme: 'dark' });
  test('three stage cards side by side on a wide screen', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto(urlOf('index.html'));
    const xs = await page.$$eval('#skills .flow .stage', (els) => els.map((e) => Math.round(e.getBoundingClientRect().left)));
    expect(xs).toHaveLength(3);
    expect(new Set(xs).size).toBe(3);
  });
  test('one stage card per row on a phone', async ({ page }) => {
    await page.setViewportSize({ width: 400, height: 900 });
    await page.goto(urlOf('index.html'));
    const boxes = await page.$$eval('#skills .flow .stage', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return { x: Math.round(r.left), y: r.top + window.scrollY }; }));
    expect(new Set(boxes.map((b) => b.x)).size).toBe(1);
    expect(boxes[1].y).toBeGreaterThan(boxes[0].y);
    expect(boxes[2].y).toBeGreaterThan(boxes[1].y);
  });
});

test.describe('tabs and popup', () => {
  test('every loop tab selects exactly itself', async ({ page }) => {
    await page.goto(urlOf('index.html'));
    const words = ['canon', 'sprint start', 'sprint-check', 'sprint complete'];
    for (let i = 0; i < 4; i++) {
      await page.click(`#s${i + 1}`);
      const sel = await page.$$eval('#loop .step', (els) => els.map((e) => e.getAttribute('aria-selected')));
      expect(sel).toEqual([0, 1, 2, 3].map((j) => String(j === i)));
      await expect(page.locator('#term')).toContainText(words[i]);
    }
  });
  test('the daily loop advances by itself, stops on a click and has a pause button', async ({ page }) => {
    await page.clock.install();
    await page.goto(urlOf('index.html'));
    const panel = page.locator('#loop .panel');
    await panel.scrollIntoViewIfNeeded();
    await expect(panel).toHaveClass(/auto/); // the observer has seen the panel on screen
    await page.clock.runFor(8200);
    await expect(page.locator('#s2')).toHaveAttribute('aria-selected', 'true');
    await page.clock.runFor(8000);
    await expect(page.locator('#s3')).toHaveAttribute('aria-selected', 'true');
    await page.click('#loop-pause');
    await expect(page.locator('#loop-pause')).toHaveText('Play');
    await expect(panel).not.toHaveClass(/auto/);
    await page.clock.runFor(17000);
    await expect(page.locator('#s3')).toHaveAttribute('aria-selected', 'true');
    await page.click('#loop-pause');
    await expect(page.locator('#loop-pause')).toHaveText('Pause');
    await page.mouse.move(0, 0);
    await expect(panel).toHaveClass(/auto/);
    await page.clock.runFor(8200);
    await expect(page.locator('#s4')).toHaveAttribute('aria-selected', 'true');
    await page.click('#s1');
    await page.mouse.move(0, 0);
    await expect(panel).not.toHaveClass(/auto/);
    await page.clock.runFor(17000);
    await expect(page.locator('#s1')).toHaveAttribute('aria-selected', 'true');
  });
  test('the daily loop stays put under reduced motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.clock.install();
    await page.goto(urlOf('index.html'));
    await page.locator('#loop .panel').scrollIntoViewIfNeeded();
    await page.clock.runFor(20000);
    await expect(page.locator('#s1')).toHaveAttribute('aria-selected', 'true');
    await expect(page.locator('#loop-pause')).toBeHidden();
  });
  test('the sprint crew pulses step by step, crosses each arrow, and can be paused', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.clock.install();
    await page.goto(urlOf('index.html'));
    const flow = page.locator('#skills .flow');
    await flow.scrollIntoViewIfNeeded();
    await expect(flow).toHaveClass(/playing/);
    const pulsing = () => page.$$eval('#skills .flow .act.pulse .act-top code', (els) => els.map((e) => e.textContent));
    expect(await pulsing()).toEqual(['research']);
    await page.clock.runFor(530);
    expect(await pulsing()).toEqual(['orient']);
    await page.clock.runFor(530 * 4); // grill, impact-analysis, root-why, then the first arrow
    await expect(page.locator('#skills .stage.st-start')).toHaveClass(/arrow-on/);
    await page.clock.runFor(910);
    expect(await pulsing()).toEqual(['code-simplifier']);
    await page.click('#flow-pause');
    await expect(page.locator('#flow-pause')).toHaveText('Play');
    await expect(flow).not.toHaveClass(/playing/);
    expect(await pulsing()).toEqual([]);
  });
  test('the sprint crew does not animate under reduced motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.clock.install();
    await page.goto(urlOf('index.html'));
    await page.locator('#skills .flow').scrollIntoViewIfNeeded();
    await page.clock.runFor(20000);
    expect(await page.$$eval('#skills .flow .pulse, #skills .flow .arrow-on', (els) => els.length)).toBe(0);
    await expect(page.locator('#flow-pause')).toBeHidden();
  });
  test('the sprint complete stage names every wrapup gate, the review and eval agents, and the summary', async ({ page }) => {
    await page.goto(urlOf('index.html'));
    const names = await page.$$eval('#skills .st-close .act-top code', (els) => els.map((e) => e.textContent));
    expect(names).toEqual(['code-simplifier', 'code-reviewer', 'security-review', 'repo-check', 'doc-audit', 'mutation-test', 'break-it', 'reviewer', 'evaluator', 'summary']);
  });
  test('every agent tab switches the screenshot', async ({ page }) => {
    await page.goto(urlOf('index.html'));
    const agents = ['claude', 'pi', 'copilot'];
    for (const a of agents) {
      await page.click(`#ag-${a}`);
      for (const b of agents) {
        await expect(page.locator(`#img-${b}`))[b === a ? 'toBeVisible' : 'toBeHidden']();
        await expect(page.locator(`#ag-${b}`)).toHaveAttribute('aria-pressed', String(b === a));
      }
    }
  });
  test('the install box switches to the Windows command', async ({ page }) => {
    await page.goto(urlOf('index.html'));
    await page.click('#os-win');
    await expect(page.locator('#install-cmd')).toContainText('irm ');
    await page.click('#os-unix');
    await expect(page.locator('#install-cmd')).toContainText('curl ');
  });
  test('the flowchart window opens and Escape closes it', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto(urlOf('learnings.html'));
    await expect(page.locator('#flowwin')).toBeHidden();
    await page.click('.flow-open');
    await expect(page.locator('#flowwin')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#flowwin')).toBeHidden();
  });
  test('the card arrows open the flowchart window too', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto(urlOf('learnings.html'));
    const arrows = page.locator('.go[data-open-flow]');
    expect(await arrows.count()).toBe(2);
    for (let i = 0; i < 2; i++) {
      await arrows.nth(i).click();
      await expect(page.locator('#flowwin')).toBeVisible();
      await page.click('#fw-close');
      await expect(page.locator('#flowwin')).toBeHidden();
    }
  });
});

test.describe('theme toggle', () => {
  for (const file of PAGES) {
    test(`${file}: the button shows the system theme and switches it both ways`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: 'dark' });
      await page.goto(urlOf(file));
      const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
      expect(luminance(await bg())).toBeLessThan(0.3);
      await expect(page.locator('#theme-label')).toHaveText('Dark');
      await page.click('#theme-toggle');
      expect(luminance(await bg())).toBeGreaterThan(0.7);
      await expect(page.locator('#theme-label')).toHaveText('Light');
      await expect(page.locator('#theme-toggle .ic[data-for="light"]')).toBeVisible();
      await expect(page.locator('#theme-toggle .ic[data-for="dark"]')).toBeHidden();
      await page.click('#theme-toggle');
      expect(luminance(await bg())).toBeLessThan(0.3);
      await expect(page.locator('#theme-label')).toHaveText('Dark');
      await expect(page.locator('#theme-toggle .ic[data-for="dark"]')).toBeVisible();
    });
  }
  test('a light system setting starts the button on Light', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'light' });
    await page.goto(urlOf('index.html'));
    await expect(page.locator('#theme-label')).toHaveText('Light');
    expect(luminance(await page.evaluate(() => getComputedStyle(document.body).backgroundColor))).toBeGreaterThan(0.7);
  });
});
