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
    // These tests temporarily replace the real tools/sprint-headless with a
    // stub so no real `claude -p` call is ever made, matching
    // tests/sprint-check-api-parity.sh's own approach for the same reason.
    // Restored in a finally block per test — never left swapped even on
    // failure, since these tests run serially within this single file/worker.
    const SPRINT_HEADLESS_PATH = path.join(PROJECT_ROOT, 'tools', 'sprint-headless');

    function installStub(scriptBody) {
      const backup = fs.readFileSync(SPRINT_HEADLESS_PATH, 'utf8');
      fs.writeFileSync(SPRINT_HEADLESS_PATH, scriptBody, { mode: 0o755 });
      return () => fs.writeFileSync(SPRINT_HEADLESS_PATH, backup, { mode: 0o755 });
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
      const restore = installStub([
        '#!/usr/bin/env bash', 'sleep 1', 'echo "stub pass output"', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(BASE);
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
        restore();
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('a claude -p failure surfaces its real error text, not a generic message', async ({ page }) => {
      const id = 't-hlf1';
      ciTicket(id);
      const restore = installStub([
        '#!/usr/bin/env bash',
        'echo "Error: claude -p invocation failed (exit 1). Hard-failing." >&2',
        'exit 1', '',
      ].join('\n'));
      try {
        await page.goto(BASE);
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
        restore();
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('elapsed time increases while a slow run is in progress', async ({ page }) => {
      const id = 't-hle1';
      ciTicket(id);
      const restore = installStub([
        '#!/usr/bin/env bash', 'sleep 8', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(BASE);
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
        restore();
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('a second trigger while one is running does not start a second subprocess', async ({ page }) => {
      const id = 't-hld1';
      ciTicket(id);
      const restore = installStub([
        '#!/usr/bin/env bash',
        'echo "$$-$(date +%s%N)" >> "' + path.join(PROJECT_ROOT, '.tickets', id, 'run-markers.txt') + '"',
        'sleep 5', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(BASE);
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
        restore();
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('step flow (t-1262): idle/running/done states, click-to-expand descriptions', async ({ page }) => {
      const id = 't-hls1';
      ciTicket(id);
      const restore = installStub([
        '#!/usr/bin/env bash', 'sleep 2', 'echo "stub output"', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(BASE);
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
        restore();
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('step flow shows a fail-colored final step on a FAIL verdict', async ({ page }) => {
      const id = 't-hls2';
      ciTicket(id);
      const restore = installStub([
        '#!/usr/bin/env bash', 'echo "stub fail output"', 'echo "HEADLESS_VERDICT: FAIL"', 'exit 1',
      ].join('\n'));
      try {
        await page.goto(BASE);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        await page.locator(`.card[data-id="${id}"] .ci-run-btn`).click();
        await page.waitForTimeout(400); // idle-pickup fetch in renderModalHeadless
        await page.locator('#m-headless-baseref').fill('main');
        await page.locator('#m-headless-run').click();
        await expect(page.locator('#m-headless .headless-step').nth(2)).toHaveClass(/fail/, { timeout: 10000 });
      } finally {
        restore();
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('card-level Run button shows a custom tooltip, not the native title attribute', async ({ page }) => {
      const id = 't-hls3';
      ciTicket(id);
      try {
        await page.goto(BASE);
        await page.waitForLoadState('networkidle');
        await page.locator('#board-search').fill(id);
        await page.waitForTimeout(200);
        const runBtn = page.locator(`.card[data-id="${id}"] .ci-run-btn`);
        await expect(runBtn).not.toHaveAttribute('title', /.+/);
        await runBtn.hover();
        await expect(page.locator('#ci-run-tooltip')).toHaveClass(/visible/);
        await expect(page.locator('#ci-run-tooltip')).toHaveText('Run headless grading');
        await page.mouse.move(0, 0);
        await expect(page.locator('#ci-run-tooltip')).not.toHaveClass(/visible/);
      } finally {
        fs.rmSync(path.join(PROJECT_ROOT, '.tickets', id), { recursive: true, force: true });
      }
    });

    test('card-level run button pulses while a run is in progress, and clears after it completes (t-dd51)', async ({ page }) => {
      const id = 't-hlr1';
      ciTicket(id);
      const restore = installStub([
        '#!/usr/bin/env bash', 'sleep 12', 'echo "HEADLESS_VERDICT: PASS"', 'exit 0', '',
      ].join('\n'));
      try {
        await page.goto(BASE);
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
        restore();
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
