// @ts-check
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const { execFileSync, spawn } = require('child_process');
const net = require('net');

const BASE = process.env.SPRINT_CHECK_BASE || 'http://localhost:8423';
const PROJECT_ROOT = process.env.SPRINT_CHECK_TEST_ROOT || process.cwd();

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

  test('Description tab appears on tickets with docs, absent on doc-less tickets', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    // First card (newest open ticket) has docs — Description tab should appear
    const firstCard = page.locator('.card').first();
    await firstCard.click();
    await page.waitForSelector('#m-docs', { timeout: 5000 });
    const withDocsTabs = await page.locator('#m-docs .doc-tab').allTextContents();
    expect(withDocsTabs.map(t => t.trim())).toContain('Description');
    await page.keyboard.press('Escape');
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

  test('hovering the ready indicator shows the readiness popover', async ({ page }) => {
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
        'Use the existing board readiness popover.',
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
      await indicator.hover();
      await expect(page.locator('#ready-popover')).toBeVisible();
      await expect(page.locator('#ready-popover')).toContainText('Signed off');
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
        'Use the existing board readiness popover.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id);
      const indicator = page.locator(`.card[data-id="${id}"] .ready-indicator`);
      await expect(indicator).toContainText('needs signoff');
      await expect(indicator).not.toContainText('ready');
      await indicator.hover();
      await expect(page.locator('#ready-popover')).toContainText('Sign-off');
      await expect(page.locator('#ready-popover')).not.toContainText('Signed off');
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
        'Use the existing board readiness popover.',
        '',
      ].join('\n'));

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      await page.locator('#board-search').fill(id);
      const indicator = page.locator(`.card[data-id="${id}"] .ready-indicator`);
      await expect(indicator).toContainText('unchecked items');
      await expect(indicator).not.toContainText('ready');
      await indicator.hover();
      await expect(page.locator('#ready-popover')).toContainText('unchecked item remains');
      await expect(page.locator('#ready-popover')).not.toContainText('Signed off');
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

  test('mockup image referenced via markdown renders inline in the doc', async ({ page }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(path.join(ticketDir, 'mockups'), { recursive: true });
      // 1x1 transparent PNG — real, decodable bytes, not just a magic-number stub,
      // so the browser actually loads it rather than firing an error event.
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
        'base64'
      );
      fs.writeFileSync(path.join(ticketDir, 'mockups', 'chosen.png'), png);

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
        '![Chosen mockup](mockups/chosen.png)',
        '',
      ].join('\n'));

      await page.goto(`${BASE}?debug=1`);
      await page.waitForLoadState('networkidle');
      await page.locator('#board-search').fill(id);
      await page.locator(`.card[data-id="${id}"]`).click();
      await expect(page.locator('#modal-overlay')).toHaveClass(/open/);
      await page.locator('.doc-tab', { hasText: 'Plan' }).click();
      await expect(page.locator('.doc-tab.active')).toHaveText('Plan');

      const img = page.locator('#m-body img.doc-mockup-img');
      await expect(img).toBeVisible();
      await expect(img).toHaveAttribute('src', `/api/ticket-image/${id}/mockups/chosen.png`);
      // Confirm the browser actually decoded real image bytes, not a broken-image icon.
      await expect.poll(() => img.evaluate(el => el.naturalWidth)).toBeGreaterThan(0);

      // Raw markdown syntax must not leak through as literal text once rendered.
      await expect(page.locator('#m-body')).not.toContainText('![Chosen mockup]');
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('a crafted ticket-image path is rejected, not served', async ({ request }) => {
    const id = `t-${Math.random().toString(36).slice(2, 6).padEnd(4, '0')}`;
    const ticketDir = path.join(PROJECT_ROOT, '.tickets', id);

    try {
      fs.mkdirSync(path.join(ticketDir, 'mockups'), { recursive: true });
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

      const missing = await request.get(`${BASE}/api/ticket-image/${id}/mockups/does-not-exist.png`);
      expect(missing.status()).toBe(404);
    } finally {
      fs.rmSync(ticketDir, { recursive: true, force: true });
    }
  });

  test('a quote-breaking mockup src cannot inject a live HTML attribute', async ({ page }) => {
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
      await expect(page.locator('#m-body img.doc-mockup-img')).toBeVisible();

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
      fs.mkdirSync(path.join(ticketDir, 'mockups'), { recursive: true });
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
        'base64'
      );
      fs.writeFileSync(path.join(ticketDir, 'mockups', 'real.png'), png);

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
        'A real image reference: ![real mockup](mockups/real.png)',
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
      const codeTexts = await body.locator('code.doc-code').allTextContents();
      expect(codeTexts).toContain('![alt](src)');
      expect(codeTexts).toContain('**not bold**');
      expect(codeTexts).toContain('a|b|c');

      const boldTexts = await body.locator('strong').allTextContents();
      expect(boldTexts).not.toContain('not bold');

      const img = body.locator('img.doc-mockup-img');
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
        '| Uses embed | pass | `standards/ticket-layout.md:1 — "already-saved \\`mockups/x.png\\` candidate, must be a real markdown image embed — \\`![alt](mockups/ghost.png)\\` — never a bare mention."` |',
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
      // as a broken <img> pointing at a nonexistent mockups/ghost.png.
      const codeTexts = await body.locator('code.doc-code').allTextContents();
      const citation = codeTexts.find(t => t.includes('mockups/ghost.png'));
      expect(citation).toBeTruthy();
      expect(citation).toContain('`mockups/x.png`');
      expect(citation).toContain('`![alt](mockups/ghost.png)`');
      expect(citation).not.toContain('\\`');

      await expect(body.locator('img.doc-mockup-img')).toHaveCount(0);
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

      // Change Tier only — the Gate model suffix must survive verbatim.
      await page.locator('.signoff-tier-select').selectOption('normal');
      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: foo | Gate model: haiku');
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
      await expect.poll(() =>
        fs.readFileSync(path.join(ticketDir, 'plan.md'), 'utf8')
      ).toContain('Tier: normal | Risk: low blast radius | Gate model: haiku');

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
});
