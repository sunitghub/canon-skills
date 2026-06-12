export const FPS = 30;
export const TOTAL_S = 32;
export const TOTAL_FRAMES = TOTAL_S * FPS; // 960

// Scene start frames and durations
export const SCENES = {
  HOOK:  {start: 0,   dur: 90},   // 0–3s
  PLAN:  {start: 90,  dur: 180},  // 3–9s
  GATE1: {start: 270, dur: 120},  // 9–13s
  BUILD: {start: 390, dur: 150},  // 13–18s
  GATE2: {start: 540, dur: 150},  // 18–23s
  CLOSE: {start: 690, dur: 120},  // 23–27s
  BOARD: {start: 810, dur: 150},  // 27–32s
} as const;

export const BG      = '#0f0f10';
export const BLUE    = '#2563eb';
export const GREEN   = '#22c55e';
export const RED     = '#ef4444';
export const TEXT    = '#e2e8f0';
export const MUTED   = '#94a3b8';
export const CARD    = '#161b22';
export const BORDER  = '#1e293b';
export const TERM    = '#4ade80';   // terminal green

export const MONO = "'JetBrains Mono', 'Fira Code', 'Consolas', monospace";
export const SANS = "'-apple-system', 'BlinkMacSystemFont', 'Inter', sans-serif";
