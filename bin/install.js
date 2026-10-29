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
  // t-50f7: the install is versioned: TARGET/packages/<vX.Y.Z>/ (or packages/main, a clone) and TARGET/current, a link to one of them.
  // TARGET stays the home: it also holds the data (cockpit/, events/, ...). An older install is a clone at TARGET itself.
  let tools = path.join(TARGET, 'current', 'tools');

  if (fs.existsSync(path.join(tools, 'skills.sh')) || fs.existsSync(path.join(TARGET, 'tools', 'skills.sh'))) {
    if (!fs.existsSync(path.join(tools, 'skills.sh'))) tools = path.join(TARGET, 'tools');
    ok(`canon already installed at ${TARGET}`);
    info('Updating…');
    // an explicit CANON_REF picks the version; otherwise the install keeps its own track
    const canon = path.join(tools, 'canon');
    const r = spawnSync('bash', ref ? [canon, 'update', '--to', ref] : [canon, 'update'], { stdio: 'inherit' });
    if (r.status !== 0) {
      warn('canon update did not finish — nothing was changed, or your local changes conflict. Skipping update.');
    }
  } else {
    header(`Installing canon → ${TARGET}`);
    // on failure remove only what this run made: an existing folder (empty, or holding data kept from an earlier install) is the user's
    const existed = fs.existsSync(TARGET);
    const pkgs = path.join(TARGET, 'packages');
    const pkgsExisted = fs.existsSync(pkgs);
    fs.mkdirSync(pkgs, { recursive: true });
    // the clone only carries the code that builds the layout: inside packages/ under a dot name, removed once it is done (as install.sh)
    const boot = fs.mkdtempSync(path.join(pkgs, '.boot.'));
    const undo = () => {
      fs.rmSync(boot, { recursive: true, force: true });
      if (!existed) { fs.rmSync(TARGET, { recursive: true, force: true }); return; }
      if (!pkgsExisted) fs.rmSync(pkgs, { recursive: true, force: true });
      try { if (fs.lstatSync(path.join(TARGET, 'current')).isSymbolicLink()) fs.rmSync(path.join(TARGET, 'current')); } catch (e) { /* none made */ }
    };
    const r = spawnSync('git', ['clone', '--depth', '1', '--', REPO, boot], { stdio: 'inherit' });
    if (r.status !== 0) {
      undo();
      console.error('\n  \x1b[31m✗\x1b[0m  Clone failed. Check your git config and try again.');
      process.exit(1);
    }
    // install the verified release (or the requested ref); if that cannot be verified nothing is left installed
    const u = spawnSync('bash', [path.join(boot, 'tools', 'canon'), 'update', '--to', ref || 'latest'], { stdio: 'inherit' });
    if (u.status !== 0) {
      undo();
      console.error('\n  \x1b[31m✗\x1b[0m  Could not install a verified canon release, so nothing was installed.');
      console.error('     To install the development version instead: CANON_REF=main  (then run this again)');
      process.exit(1);
    }
    fs.rmSync(boot, { recursive: true, force: true });
    ok('Installed.');
  }

  // ── Run init ──────────────────────────────────────────────────────────────

  header('Wiring agent hooks…');
  const init = spawnSync('bash', [path.join(tools, 'skills.sh'), 'init'], { stdio: 'inherit' });
  if (init.status !== 0) {
    warn('skills.sh init reported an issue — check output above.');
  }

  // ── Done ──────────────────────────────────────────────────────────────────

  header('Done.');
  console.log(`
  Full setup guide: ${path.join(tools, '..', 'docs', 'setup.md')}
`);
}

if (require.main === module) {
  main();
}

module.exports = { resolveTarget, expandTilde };
