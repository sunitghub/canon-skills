// Shared behavior for every page. Each feature runs only when its element is present.
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }

  // Theme: one button shows the current theme and switches it. With no choice made the system setting decides.
  var root = document.documentElement;
  var themeBtn = $('theme-toggle');
  if (themeBtn) {
    var systemLight = window.matchMedia ? matchMedia('(prefers-color-scheme: light)') : null;
    var currentTheme = function () { return root.dataset.theme || (systemLight && systemLight.matches ? 'light' : 'dark'); };
    var paintTheme = function () {
      var t = currentTheme();
      $('theme-label').textContent = t === 'dark' ? 'Dark' : 'Light';
      // SVG elements have no .hidden property, so toggle the attribute
      themeBtn.querySelectorAll('.ic').forEach(function (ic) { ic.toggleAttribute('hidden', ic.dataset.for !== t); });
      themeBtn.setAttribute('aria-label', 'Switch to ' + (t === 'dark' ? 'light' : 'dark') + ' theme');
    };
    themeBtn.onclick = function () {
      root.dataset.theme = currentTheme() === 'dark' ? 'light' : 'dark';
      paintTheme();
    };
    if (systemLight && systemLight.addEventListener) systemLight.addEventListener('change', paintTheme);
    paintTheme();
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
    // Auto-advance every few seconds while the panel is on screen. It pauses on hover and focus, stops for good
    // after a click, never runs under reduced motion, and has a Pause button (WCAG 2.2.2).
    var panel = term.closest('.panel');
    var pauseBtn = $('loop-pause');
    var current = 0, timer = null, userStopped = false, hovering = false, onScreen = false;
    var reduceMotion = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    var STEP_MS = 8000;
    var select = function (i) { current = i; showStep(i); };
    var running = function () { return !userStopped && !hovering && onScreen && !document.hidden && !reduceMotion; };
    var schedule = function () {
      clearTimeout(timer);
      panel.classList.remove('auto');
      if (!running()) return;
      void panel.offsetWidth; // restart the progress line
      panel.classList.add('auto');
      timer = setTimeout(function () { select((current + 1) % steps.length); schedule(); }, STEP_MS);
    };
    var paintPause = function () { if (pauseBtn) pauseBtn.textContent = userStopped ? 'Play' : 'Pause'; };
    steps.forEach(function (_, k) {
      $('s' + (k + 1)).onclick = function () { userStopped = true; paintPause(); select(k); schedule(); };
    });
    if (pauseBtn) {
      if (reduceMotion) pauseBtn.hidden = true;
      pauseBtn.onclick = function () { userStopped = !userStopped; paintPause(); schedule(); };
    }
    panel.addEventListener('mouseenter', function () { hovering = true; schedule(); });
    panel.addEventListener('mouseleave', function () { hovering = false; schedule(); });
    panel.addEventListener('focusin', function () { hovering = true; schedule(); });
    panel.addEventListener('focusout', function () { hovering = false; schedule(); });
    document.addEventListener('visibilitychange', schedule);
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) { onScreen = entries[0].isIntersecting; schedule(); }, { threshold: 0.35 }).observe(panel);
    }
    select(0);
  }

  // Home: the sprint crew. A pulse walks each stage's steps in order, crosses the arrow, and moves on to the next
  // stage, then starts over. Same rules as the daily loop: on screen only, paused on hover or focus, a Pause
  // button, and none of it under reduced motion.
  var crew = document.querySelector('#skills .flow');
  if (crew) {
    var crewPause = $('flow-pause');
    var crewReduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    var beats = [];
    var crewStages = [].slice.call(crew.querySelectorAll('.stage'));
    crewStages.forEach(function (st, i) {
      st.querySelectorAll('.act').forEach(function (a) { beats.push({ el: a, cls: 'pulse', ms: 520 }); });
      if (i < crewStages.length - 1) beats.push({ el: st, cls: 'arrow-on', ms: 900 });
    });
    var beat = 0, crewTimer = null, crewStopped = false, crewHover = false, crewOnScreen = false;
    var crewRunning = function () { return !crewStopped && !crewHover && crewOnScreen && !document.hidden && !crewReduce; };
    var clearBeats = function () { beats.forEach(function (b) { b.el.classList.remove(b.cls); }); };
    var playBeat = function () {
      clearTimeout(crewTimer);
      clearBeats();
      crew.classList.toggle('playing', crewRunning());
      if (!crewRunning()) return;
      var b = beats[beat];
      b.el.classList.add(b.cls);
      crewTimer = setTimeout(function () {
        b.el.classList.remove(b.cls);
        beat = (beat + 1) % beats.length;
        if (beat === 0) crewTimer = setTimeout(playBeat, 1800); else playBeat();
      }, b.ms);
    };
    if (crewPause) {
      if (crewReduce) crewPause.hidden = true;
      crewPause.onclick = function () { crewStopped = !crewStopped; crewPause.textContent = crewStopped ? 'Play' : 'Pause'; playBeat(); };
    }
    crew.addEventListener('mouseenter', function () { crewHover = true; playBeat(); });
    crew.addEventListener('mouseleave', function () { crewHover = false; playBeat(); });
    crew.addEventListener('focusin', function () { crewHover = true; playBeat(); });
    crew.addEventListener('focusout', function () { crewHover = false; playBeat(); });
    document.addEventListener('visibilitychange', playBeat);
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) { crewOnScreen = entries[0].isIntersecting; playBeat(); }, { threshold: 0.15 }).observe(crew);
    }
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
