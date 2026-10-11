// t-1543: the board's one entry module (app.html loads only this). The board-*.js modules only declare; their
// load-time code is an init function, run here in the old script order once every module has loaded, so an
// import cycle can never run one file's code before another's top-level let/const is initialized.
import { initCore } from './board-core.js';
import { initRender } from './board-render.js';
import { initDocs } from './board-docs.js';
import { initCockpit } from './board-cockpit.js';
import { initCockpitRail } from './board-cockpit-rail.js';
import { initWorktree } from './board-worktree.js';
import { initPanels } from './board-panels.js';
import { initCreate } from './board-create.js';
import { initUi } from './board-ui.js';

initCore();
initRender();
initDocs();
initCockpit();
initCockpitRail();
initWorktree();
initPanels();
initCreate();
initUi();
