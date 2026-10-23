#!/usr/bin/env node

'use strict';

const { spawnSync } = require('child_process');
const os   = require('os');
const path = require('path');
const fs   = require('fs');

const REPO = process.env.CANON_REPO || 'https://github.com/sunitghub/canon-skills.git';   // the override is a test seam (as in install.sh)

function expandTilde(p, home) {
  if (p === '~') return home;
  if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(home, p.slice(2));
  return p;
}

// Install target precedence: positional arg > CANON_HOME env > ~/.canon
function resolveTarget({ argv, env, home }) {
  const arg = argv[2] && !argv[2].startsWith('-') ? argv[2] : undefined;
  const raw = arg || env.CANON_HOME || path.join(home, '.canon');
  return path.resolve(expandTilde(raw, home));
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

function main() {
  const TARGET = resolveTarget({ argv: process.argv, env: process.env, home: os.homedir() });

  console.log(`\x1b[96m${LOGO}\x1b[0m`);
  header('canon-skills installer');

  // ── Clone or update (t-2ea4: the same steps as install.sh) ──────────────
  // A new install is the latest verified release (`canon update`); CANON_REF=main installs the
  // development track, CANON_REF=vX.Y.Z a version.

  const ref = process.env.CANON_REF || '';
  const canon = path.join(TARGET, 'tools', 'canon');

  if (fs.existsSync(path.join(TARGET, 'tools', 'skills.sh'))) {
    ok(`canon already installed at ${TARGET}`);
    info('Updating…');
    // an explicit CANON_REF picks the version; otherwise the install keeps its own track
    const r = spawnSync('bash', ref ? [canon, 'update', '--to', ref] : [canon, 'update'], { stdio: 'inherit' });
    if (r.status !== 0) {
      warn('canon update did not finish — nothing was changed, or your local changes conflict. Skipping update.');
    }
  } else {
    header(`Cloning canon → ${TARGET}`);
    fs.mkdirSync(path.dirname(TARGET), { recursive: true });
    // an existing (empty) folder is the user's: on failure clean its contents, never the folder itself
    const existed = fs.existsSync(TARGET);
    const r = spawnSync('git', ['clone', '--depth', '1', '--', REPO, TARGET], { stdio: 'inherit' });
    if (r.status !== 0) {
      console.error('\n  \x1b[31m✗\x1b[0m  Clone failed. Check your git config and try again.');
      process.exit(1);
    }
    // move the clone to the verified release (or the requested ref); if that cannot be verified nothing is left installed
    const u = spawnSync('bash', [canon, 'update', '--to', ref || 'latest'], { stdio: 'inherit' });
    if (u.status !== 0) {
      if (existed) {
        for (const e of fs.readdirSync(TARGET)) fs.rmSync(path.join(TARGET, e), { recursive: true, force: true });
      } else {
        fs.rmSync(TARGET, { recursive: true, force: true });
      }
      console.error('\n  \x1b[31m✗\x1b[0m  Could not install a verified canon release, so nothing was installed.');
      console.error('     To install the development version instead: CANON_REF=main  (then run this again)');
      process.exit(1);
    }
    ok('Cloned.');
  }

  // ── Run init ──────────────────────────────────────────────────────────────

  header('Wiring agent hooks…');
  const init = spawnSync('bash', [path.join(TARGET, 'tools', 'skills.sh'), 'init'], { stdio: 'inherit' });
  if (init.status !== 0) {
    warn('skills.sh init reported an issue — check output above.');
  }

  // ── Cockpit daemon ────────────────────────────────────────────────────────
  // gitignored, so a clone has none: fetch the verified prebuilt (or build it). Never fatal.

  const daemon = spawnSync('bash', [path.join(TARGET, 'tools', 'fetch-daemon.sh')], { stdio: 'inherit' });
  if (daemon.status !== 0) {
    warn('agent sessions in the Cockpit need the daemon; see the message above, or run: canon update');
  }

  // ── Done ──────────────────────────────────────────────────────────────────

  header('Done.');
  console.log(`
  Full setup guide: ${TARGET}/docs/setup.md
`);
}

if (require.main === module) {
  main();
}

module.exports = { resolveTarget, expandTilde };
