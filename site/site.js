// Shared behavior for every page. Each feature runs only when its element is present.
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }

  // Theme: Ink (dark) and Paper (light). With no choice made, the system setting decides via CSS.
  var root = document.documentElement;
  var ink = $('t-ink'), paper = $('t-paper');
  if (ink && paper) {
    var setTheme = function (t) {
      root.dataset.theme = t;
      ink.setAttribute('aria-pressed', t === 'dark');
      paper.setAttribute('aria-pressed', t === 'light');
    };
    var prefersLight = window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches;
    if (!root.dataset.theme) {
      ink.setAttribute('aria-pressed', !prefersLight);
      paper.setAttribute('aria-pressed', prefersLight);
    }
    ink.onclick = function () { setTheme('dark'); };
    paper.onclick = function () { setTheme('light'); };
  }

  // Install box: optional OS tabs, copy button.
  var cmdEl = $('install-cmd'), copyBtn = $('copy-install');
  if (cmdEl && copyBtn) {
    var cmds = {
      unix: { prompt: '$', plain: 'curl -fsSL https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.sh | bash' },
      win: { prompt: '>', plain: 'irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex' }
    };
    var os = 'unix';
    var tabUnix = $('os-unix'), tabWin = $('os-win');
    if (tabUnix && tabWin) {
      var setOS = function (k) {
        os = k;
        var mark = document.createElement('i');
        mark.textContent = cmds[k].prompt;
        cmdEl.textContent = '';
        cmdEl.appendChild(mark);
        cmdEl.appendChild(document.createTextNode(cmds[k].plain));
        tabUnix.setAttribute('aria-pressed', k === 'unix');
        tabWin.setAttribute('aria-pressed', k === 'win');
      };
      tabUnix.onclick = function () { setOS('unix'); };
      tabWin.onclick = function () { setOS('win'); };
    }
    copyBtn.onclick = function () {
      var text = tabUnix ? cmds[os].plain : cmdEl.textContent.replace(/^[$>]/, '');
      var done = function () { copyBtn.textContent = 'Copied'; setTimeout(function () { copyBtn.textContent = 'Copy'; }, 1500); };
      var fallback = function () {
        var r = document.createRange(); r.selectNodeContents(cmdEl);
        var s = getSelection(); s.removeAllRanges(); s.addRange(r);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback); else fallback();
    };
  }

  // Home: the daily-loop panel.
  var term = $('term'), tree = $('tree'), treeNote = $('tree-note');
  if (term && tree && treeNote) {
    var steps = [
      {
        term: '<span class="p">$</span> canon\nCanon Cockpit already running on port 8899 — opening it.\n\n<span class="dim"># in the Cockpit</span>\n<span class="acc">+ Add Project</span>  ~/Developer/my-app  <span class="dim">git repo</span>\n<span class="acc">+ sprint</span>       skill registered\n<span class="acc">Scratch</span>       agent open, no ticket yet',
        tree: [['dir', 'my-app/'], ['kid hot', 'AGENTS.md', 'sprint registered'], ['kid hot', 'CLAUDE.md', '@AGENTS.md import'], ['kid hot', '.claude/skills/', 'sprint symlink'], ['kid', '.tickets/']],
        note: 'Registering a skill from the card does what skills.sh add does. Folders without git work too; the git icon turns on version history.'
      },
      {
        term: '<span class="p">$</span> sprint start "add OAuth login"\n<span class="ok">✓</span> ticket t-4f2a created  <span class="dim">.tickets/t-4f2a/</span>\n<span class="ok">✓</span> plan.md written: 3 steps, 2 rejected alternatives\n<span class="ok">✓</span> acceptance.md: 4 criteria, none checked\n<span class="acc">→</span> waiting for your approval before any code',
        tree: [['dir', '.tickets/t-4f2a/'], ['kid hot', 'ticket.md', 'goal + tier'], ['kid hot', 'plan.md', 'steps, rejected options'], ['kid hot', 'acceptance.md', '4 criteria'], ['dir', 'HANDOFF.md']],
        note: 'The plan is on disk before the agent writes a line of code. You approve it, or change it. Started from a scratch session, it resumes the same conversation.'
      },
      {
        term: '<span class="p">$</span> sprint-check\nOpening this project in the running Canon Cockpit (port 8899).\n\n  <span class="dim">open</span> 11   <span class="dim">in progress</span> 1   <span class="dim">done</span> 771   <span class="dim">discarded</span> 32\n\n<span class="dim">reads .tickets/, HANDOFF.md and git log. No account, no remote.</span>',
        tree: [['dir', '.tickets/'], ['kid hot', 't-4f2a/', 'card: in progress'], ['dir hot', 'HANDOFF.md', 'current focus'], ['dir hot', '.git/', 'commits link to tickets']],
        note: 'The board is a view over files you already have. It opens this project’s tab in the Cockpit.'
      },
      {
        term: '<span class="p">$</span> sprint complete\n<span class="acc">evaluator</span>  fresh subagent · Read+Bash · no build history\n  <span class="ok">✓</span> AC1  token refresh handles expiry     <span class="dim">src/auth.py:88</span>\n  <span class="bad">✗</span> AC3  logout clears session cookie     <span class="dim">not found</span>\n<span class="bad">verdict: fail</span>  1 criterion unmet · close refused\n\n<span class="dim">…fix, re-run…</span>\n<span class="ok">verdict: pass</span>  4/4 · summary.md written',
        tree: [['dir', '.tickets/t-4f2a/'], ['kid', 'plan.md'], ['kid hot', 'eval-report.md', 'file:line per verdict'], ['kid hot', 'review-notes.md', 'advisory findings'], ['kid hot', 'summary.md', 'plan vs actual']],
        note: 'The close is mechanical. Unchecked box, missing summary or a non-pass verdict and the CLI says no.'
      }
    ];
    var showStep = function (i) {
      var s = steps[i];
      term.innerHTML = s.term;
      tree.innerHTML = s.tree.map(function (r) {
        return '<li class="' + r[0] + '"' + (r[2] ? ' data-note="' + r[2] + '"' : '') + '>' + r[1] + '</li>';
      }).join('');
      treeNote.textContent = s.note;
      steps.forEach(function (_, j) { $('s' + (j + 1)).setAttribute('aria-selected', j === i); });
    };
    steps.forEach(function (_, j) { $('s' + (j + 1)).onclick = function () { showStep(j); }; });
    showStep(0);
  }

  // Home: agent tabs switch the screenshot.
  var agents = ['claude', 'pi', 'copilot'];
  if ($('ag-claude')) {
    agents.forEach(function (a) {
      $('ag-' + a).onclick = function () {
        agents.forEach(function (b) {
          $('ag-' + b).setAttribute('aria-pressed', b === a);
          $('img-' + b).hidden = b !== a;
        });
      };
    });
  }

  // Learnings: non-modal flowchart window, draggable by its title bar on wide screens.
  var win = $('flowwin'), head = $('fw-head');
  if (win && head) {
    var openers = document.querySelectorAll('[data-open-flow]');
    var closeFlow = function () { win.hidden = true; };
    openers.forEach(function (b) { b.addEventListener('click', function () { win.hidden = false; }); });
    $('fw-close').onclick = closeFlow;
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeFlow(); });
    var drag = null;
    head.addEventListener('pointerdown', function (e) {
      if (e.target.tagName === 'BUTTON' || window.innerWidth < 700) return;
      var r = win.getBoundingClientRect();
      drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
      head.setPointerCapture(e.pointerId);
    });
    head.addEventListener('pointermove', function (e) {
      if (!drag) return;
      win.style.left = Math.max(0, Math.min(window.innerWidth - 120, e.clientX - drag.dx)) + 'px';
      win.style.top = Math.max(0, Math.min(window.innerHeight - 60, e.clientY - drag.dy)) + 'px';
      win.style.right = 'auto';
      win.style.bottom = 'auto';
    });
    head.addEventListener('pointerup', function () { drag = null; });
  }
})();
