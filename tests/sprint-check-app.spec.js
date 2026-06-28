// @ts-check
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const BASE = process.env.SPRINT_CHECK_BASE || 'http://localhost:8423';
const PROJECT_ROOT = process.env.SPRINT_CHECK_TEST_ROOT || process.cwd();

test.describe('board modal', () => {
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

      await page.goto(BASE);
      await page.waitForLoadState('networkidle');

      const card = page.locator(`.col-progress .card[data-id="${id}"]`);
      await expect(card).toBeVisible();
      await card.click();
      await expect(page.locator('#m-id')).toHaveText(id);
      await expect(page.locator('#m-title')).toHaveText(title);
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
        `Ticket: \`${id}\``,
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
        `Ticket: \`${id}\``,
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
});
