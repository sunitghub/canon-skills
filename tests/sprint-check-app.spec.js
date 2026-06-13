// @ts-check
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const BASE = 'http://localhost:8423';

test.describe('board modal', () => {
  test('no Description tab on any ticket', async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const firstCard = page.locator('.card').first();
    await firstCard.click();
    await page.waitForSelector('#m-docs', { timeout: 5000 });

    const tabLabels = await page.locator('#m-docs .doc-tab').allTextContents();
    expect(tabLabels.map(t => t.trim())).not.toContain('Description');
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
      const ticketDir = path.join(process.cwd(), '.tickets', createdId);
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
        fs.rmSync(path.join(process.cwd(), '.tickets', createdId), { recursive: true, force: true });
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
        fs.rmSync(path.join(process.cwd(), '.tickets', createdId), { recursive: true, force: true });
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
      const ticketDir = path.join(process.cwd(), '.tickets', createdId);
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
        fs.rmSync(path.join(process.cwd(), '.tickets', createdId), { recursive: true, force: true });
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
        fs.rmSync(path.join(process.cwd(), '.tickets', createdId), { recursive: true, force: true });
      }
    }
  });
});
