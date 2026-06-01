#!/usr/bin/env node

'use strict';

const { execSync, spawnSync } = require('child_process');
const os   = require('os');
const path = require('path');
const fs   = require('fs');

const REPO   = 'https://github.com/sunitghub/canon.git';
const TARGET = path.join(os.homedir(), 'Developer', 'canon');

function run(cmd, opts = {}) {
  return spawnSync(cmd, { shell: true, stdio: 'inherit', ...opts });
}

function header(msg) {
  console.log(`\n\x1b[1m${msg}\x1b[0m`);
}

function ok(msg)   { console.log(`  \x1b[32m✓\x1b[0m  ${msg}`); }
function info(msg) { console.log(`  \x1b[2m${msg}\x1b[0m`); }
function warn(msg) { console.log(`  \x1b[33m⚠\x1b[0m  ${msg}`); }

const LOGO = `
 ██████╗  █████╗ ███╗   ██╗ ██████╗ ███╗   ██╗
██╔════╝ ██╔══██╗████╗  ██║██╔═══██╗████╗  ██║
██║      ███████║██╔██╗ ██║██║   ██║██╔██╗ ██║
██║      ██╔══██║██║╚██╗██║██║   ██║██║╚██╗██║
╚██████╗ ██║  ██║██║ ╚████║╚██████╔╝██║ ╚████║
 ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═══╝
`;
console.log(`\x1b[96m${LOGO}\x1b[0m`);

header('canon-skills installer');

// ── Clone or update ───────────────────────────────────────────────────────

if (fs.existsSync(path.join(TARGET, 'skills.sh'))) {
  ok(`canon already installed at ${TARGET}`);
  info('Pulling latest updates…');
  const r = run(`git -C "${TARGET}" pull --ff-only`);
  if (r.status !== 0) {
    warn('git pull failed — your local changes may conflict. Skipping update.');
  }
} else {
  header(`Cloning canon → ${TARGET}`);
  fs.mkdirSync(path.dirname(TARGET), { recursive: true });
  const r = run(`git clone "${REPO}" "${TARGET}"`);
  if (r.status !== 0) {
    console.error('\n  \x1b[31m✗\x1b[0m  Clone failed. Check your git config and try again.');
    process.exit(1);
  }
  ok('Cloned.');
}

// ── Run init ──────────────────────────────────────────────────────────────

header('Wiring agent hooks…');
const init = run(`bash "${path.join(TARGET, 'skills.sh')}" init`);
if (init.status !== 0) {
  warn('skills.sh init reported an issue — check output above.');
}

// ── Done ──────────────────────────────────────────────────────────────────

header('Done.');
console.log(`
  Register skills in a project:

    cd /path/to/your-project
    ${TARGET}/skills.sh add sprint    # full dev workflow
    ${TARGET}/skills.sh addall        # advanced: all standalone skills

  Or add to your PATH for shorter commands:

    export SKILLS=${TARGET}
    $SKILLS/skills.sh add sprint

  Full setup guide: ${TARGET}/guides/AI-Agents-Setup.md
`);
