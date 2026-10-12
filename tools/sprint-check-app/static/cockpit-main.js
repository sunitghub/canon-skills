// t-565f: the Cockpit shell's one entry module (cockpit.html loads only this). The cockpit-*.js modules only
// declare; their load-time code is an init function, run here in the old script order once every module has
// loaded, so an import cycle can never run one module's code before another's top-level let/const exists.
import { initCore } from './cockpit-core.js';
import { initSessions } from './cockpit-sessions.js';
import { initSidebar } from './cockpit-sidebar.js';
import { initKeys } from './cockpit-keys.js';
import { initViews } from './cockpit-views.js';
import { initUpkeep } from './cockpit-upkeep.js';
import { initSkillEval } from './cockpit-skill-eval.js';
import { initAdmin } from './cockpit-admin.js';
import { initTabs } from './cockpit-tabs.js';
import { initProjects } from './cockpit-projects.js';

initCore();
initSessions();
initSidebar();
initKeys();
initViews();
initUpkeep();
initSkillEval();
initAdmin();
initTabs();
initProjects();
