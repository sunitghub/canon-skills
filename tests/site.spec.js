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
  test.use({ colorScheme: 'dark' });
  for (const file of PAGES) {
    test(`${file}: Paper is light and Ink is dark`, async ({ page }) => {
      await page.goto(urlOf(file));
      const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
      expect(luminance(await bg())).toBeLessThan(0.3);
      await page.click('#t-paper');
      expect(luminance(await bg())).toBeGreaterThan(0.7);
      await page.click('#t-ink');
      expect(luminance(await bg())).toBeLessThan(0.3);
    });
  }
});
