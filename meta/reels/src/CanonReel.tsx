import React from 'react';
import {
  AbsoluteFill,
  Img,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {PipelineBar} from './components/PipelineBar';
import {
  BG, BLUE, BORDER, CARD, FPS, GREEN, MONO, MUTED, RED, SANS, SCENES, TERM, TEXT, TOTAL_FRAMES,
} from './constants';

export {TOTAL_FRAMES, FPS};

// ─── Animation helpers ───────────────────────────────────────────────────────

const clamp = (val: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, val));

const fadeIn = (frame: number, start: number, dur = 20) =>
  clamp(interpolate(frame, [start, start + dur], [0, 1]), 0, 1);

const fadeOut = (frame: number, start: number, dur = 15) =>
  clamp(interpolate(frame, [start, start + dur], [1, 0]), 0, 1);

function useSpring(frame: number, from: number) {
  return spring({frame: frame - from, fps: FPS, config: {stiffness: 120, damping: 14, mass: 0.8}});
}

// ─── Shared UI atoms ─────────────────────────────────────────────────────────

const Caption: React.FC<{text: string; frame: number; showAt: number; fs: number}> = ({text, frame, showAt, fs}) => {
  const opacity = fadeIn(frame, showAt, 18);
  return (
    <div style={{
      position: 'absolute',
      bottom: 0,
      left: 0,
      right: 0,
      textAlign: 'center',
      fontFamily: SANS,
      fontSize: fs,
      fontWeight: 600,
      color: TEXT,
      opacity,
      padding: '0 32px 20px',
      letterSpacing: 0.3,
    }}>
      {text}
    </div>
  );
};

const Typewriter: React.FC<{text: string; frame: number; start: number; cps?: number; color?: string; fs: number}> = (
  {text, frame, start, cps = 10, color = TERM, fs}
) => {
  const elapsed = Math.max(0, frame - start);
  const shown = Math.min(text.length, Math.floor(elapsed / FPS * cps));
  const cursorOn = Math.floor(elapsed / 12) % 2 === 0;
  return (
    <span style={{fontFamily: MONO, fontSize: fs, color, whiteSpace: 'pre'}}>
      {text.slice(0, shown)}
      {shown < text.length && cursorOn && (
        <span style={{opacity: 0.8}}>█</span>
      )}
    </span>
  );
};

const TerminalWindow: React.FC<{children: React.ReactNode; width: number}> = ({children, width}) => (
  <div style={{
    background: '#0d1117',
    border: `1px solid ${BORDER}`,
    borderRadius: 10,
    padding: '18px 24px',
    width,
    boxSizing: 'border-box',
  }}>
    <div style={{display: 'flex', gap: 6, marginBottom: 14}}>
      {['#ff5f57','#ffbd2e','#28c840'].map((c, i) => (
        <div key={i} style={{width: 12, height: 12, borderRadius: '50%', background: c}} />
      ))}
    </div>
    {children}
  </div>
);

const FileCard: React.FC<{name: string; frame: number; showAt: number; fs: number}> = ({name, frame, showAt, fs}) => {
  const sp = useSpring(frame, showAt);
  const opacity = clamp(interpolate(frame, [showAt, showAt + 15], [0, 1]), 0, 1);
  const translateY = interpolate(sp, [0, 1], [24, 0]);
  return (
    <div style={{
      background: CARD,
      border: `1px solid ${BORDER}`,
      borderRadius: 8,
      padding: '10px 18px',
      opacity,
      transform: `translateY(${translateY}px)`,
      display: 'flex',
      alignItems: 'center',
      gap: 10,
    }}>
      <span style={{fontSize: fs * 1.1}}>📄</span>
      <span style={{fontFamily: MONO, fontSize: fs, color: TEXT}}>{name}</span>
    </div>
  );
};

// ─── Scene 1: Hook (0–90f) ───────────────────────────────────────────────────

const SceneHook: React.FC<{fs: number; termW: number}> = ({fs, termW}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <TerminalWindow width={termW}>
        <Typewriter
          text="$ sprint start &quot;add todo list&quot;"
          frame={frame}
          start={8}
          cps={12}
          fs={fs}
        />
      </TerminalWindow>
    </AbsoluteFill>
  );
};

// ─── Scene 2: Plan (90–270f, local 0–180) ────────────────────────────────────

const ScenePlan: React.FC<{fs: number; capFs: number}> = ({fs, capFs}) => {
  const frame = useCurrentFrame();
  const FILES = ['ticket.md', 'acceptance.md', 'plan.md'];
  const stagger = 40;
  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', flexDirection: 'column', gap: 18}}>
      <div style={{
        fontFamily: MONO,
        fontSize: fs * 0.75,
        color: MUTED,
        marginBottom: 8,
        opacity: fadeIn(frame, 0, 20),
      }}>
        .tickets/t-0d3b/
      </div>
      {FILES.map((name, i) => (
        <FileCard key={name} name={name} frame={frame} showAt={i * stagger + 10} fs={fs} />
      ))}
      <Caption text="Plan first. Always." frame={frame} showAt={140} fs={capFs} />
    </AbsoluteFill>
  );
};

// ─── Scene 3: Gate approved (270–390f, local 0–120) ──────────────────────────

const SceneGateApproved: React.FC<{fs: number; capFs: number}> = ({fs, capFs}) => {
  const frame = useCurrentFrame();
  const sp = useSpring(frame, 15);
  const scale = interpolate(sp, [0, 1], [0.7, 1]);
  const opacity = clamp(interpolate(frame, [10, 30], [0, 1]), 0, 1);
  const checkOpacity = fadeIn(frame, 50, 20);
  const checkScale = interpolate(useSpring(frame, 50), [0, 1], [0.5, 1]);
  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <div style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 20,
        opacity,
        transform: `scale(${scale})`,
      }}>
        <div style={{
          border: `3px solid ${BLUE}`,
          borderRadius: 12,
          padding: '20px 40px',
          background: `${BLUE}15`,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 10,
        }}>
          <div style={{fontFamily: MONO, fontSize: fs * 0.75, color: MUTED, letterSpacing: 2}}>GATE</div>
          <div style={{
            fontFamily: MONO,
            fontSize: fs * 1.3,
            color: BLUE,
            fontWeight: 700,
            opacity: checkOpacity,
            transform: `scale(${checkScale})`,
          }}>
            ✓ Approved
          </div>
        </div>
      </div>
      <Caption text="Nothing ships without a brief." frame={frame} showAt={65} fs={capFs} />
    </AbsoluteFill>
  );
};

// ─── Scene 4: Build (390–540f, local 0–150) ──────────────────────────────────

const CODE_LINES = [
  'function TodoList() {',
  '  const [items, setItems] = useState([]);',
  '  return (',
  '    <ul>{items.map(i => <Item key={i.id}',
  '      text={i.text} />)}</ul>',
];

const SYNTAX: Record<string, string> = {
  'function': '#c792ea',
  'const': '#c792ea',
  'return': '#c792ea',
  'useState': '#82aaff',
};

function colorize(line: string, baseFs: number) {
  const words = line.split(/(\b\w+\b|[<>/(){}[\]=,;.\s]+)/g);
  return words.map((w, i) => (
    <span key={i} style={{color: SYNTAX[w] ?? (w.startsWith('<') || w.startsWith('/') ? '#89ddff' : TEXT)}}>
      {w}
    </span>
  ));
}

const SceneBuild: React.FC<{fs: number}> = ({fs}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <TerminalWindow width={Math.min(700, fs * 22)}>
        {CODE_LINES.map((line, i) => {
          const showAt = i * 22 + 5;
          const opacity = fadeIn(frame, showAt, 12);
          const x = interpolate(clamp(frame - showAt, 0, 12), [0, 12], [-10, 0]);
          return (
            <div key={i} style={{
              fontFamily: MONO,
              fontSize: fs * 0.8,
              opacity,
              transform: `translateX(${x}px)`,
              lineHeight: 1.7,
              whiteSpace: 'pre',
            }}>
              {colorize(line, fs)}
            </div>
          );
        })}
      </TerminalWindow>
    </AbsoluteFill>
  );
};

// ─── Scene 5: Gate blocked → resolved (540–690f, local 0–150) ────────────────

const SceneGateBlocked: React.FC<{fs: number; capFs: number}> = ({fs, capFs}) => {
  const frame = useCurrentFrame();

  const BLOCK_END = 75;    // red state: local 0–75 (2.5s)
  const RESOLVE_START = 75;

  // Red block: slides in
  const blockOpacity = fadeIn(frame, 5, 15);
  const blockX = interpolate(clamp(frame - 5, 0, 20), [0, 20], [-30, 0]);

  // Shake: 0–60
  const shakeX = frame < 60
    ? interpolate(frame % 8, [0, 2, 4, 6, 8], [0, -6, 6, -4, 0])
    : 0;

  // Checkboxes tick at resolve
  const cb1Checked = frame >= RESOLVE_START + 10;
  const cb2Checked = frame >= RESOLVE_START + 28;
  const cb1Scale = cb1Checked ? interpolate(clamp(frame - (RESOLVE_START + 10), 0, 12), [0, 12], [0.5, 1]) : 1;
  const cb2Scale = cb2Checked ? interpolate(clamp(frame - (RESOLVE_START + 28), 0, 12), [0, 12], [0.5, 1]) : 1;

  // Color transition: red → green after both checked
  const isResolved = frame >= RESOLVE_START + 45;
  const colorTransition = clamp(interpolate(frame, [RESOLVE_START + 45, RESOLVE_START + 60], [0, 1]), 0, 1);
  const blockColor = isResolved
    ? `rgb(${lerp(239, 34, colorTransition)}, ${lerp(68, 197, colorTransition)}, ${lerp(68, 94, colorTransition)})`
    : RED;

  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <div style={{
        opacity: blockOpacity,
        transform: `translateX(${blockX + shakeX}px)`,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'flex-start',
        gap: 12,
        minWidth: Math.min(560, fs * 18),
      }}>
        {/* Header bar */}
        <div style={{
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          background: `${blockColor}18`,
          border: `2px solid ${blockColor}`,
          borderRadius: 10,
          padding: '14px 22px',
          width: '100%',
          boxSizing: 'border-box',
          transition: 'none',
        }}>
          <span style={{fontSize: fs * 1.2}}>{isResolved ? '✅' : '❌'}</span>
          <div>
            <div style={{fontFamily: MONO, fontSize: fs * 0.8, color: blockColor, fontWeight: 700}}>
              sprint complete
            </div>
            <div style={{fontFamily: MONO, fontSize: fs * 0.65, color: isResolved ? GREEN : RED, marginTop: 4}}>
              {isResolved ? '✓ all gates passed' : '✗ 2 items unchecked'}
            </div>
          </div>
        </div>

        {/* Checklist items */}
        {[
          {label: '[ ] tests passing', checkedAt: RESOLVE_START + 10, scale: cb1Scale, checked: cb1Checked},
          {label: '[ ] QA sign-off', checkedAt: RESOLVE_START + 28, scale: cb2Scale, checked: cb2Checked},
        ].map(({label, checked, scale}) => {
          const itemColor = checked ? GREEN : MUTED;
          return (
            <div key={label} style={{
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              opacity: fadeIn(frame, 8, 15),
              paddingLeft: 8,
            }}>
              <span style={{
                fontSize: fs * 1.1,
                transform: `scale(${scale})`,
                display: 'inline-block',
              }}>
                {checked ? '✅' : '⬜'}
              </span>
              <span style={{fontFamily: MONO, fontSize: fs * 0.75, color: itemColor,
                textDecoration: checked ? 'line-through' : 'none'}}>
                {checked ? label.replace('[ ]', '[x]') : label}
              </span>
            </div>
          );
        })}
      </div>
      <Caption text="The gate doesn't ask nicely." frame={frame} showAt={20} fs={capFs} />
    </AbsoluteFill>
  );
};

function lerp(a: number, b: number, t: number) {
  return Math.round(a + (b - a) * t);
}

// ─── Scene 6: Close (690–810f, local 0–120) ───────────────────────────────────

const SceneClose: React.FC<{fs: number; capFs: number}> = ({fs, capFs}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <TerminalWindow width={Math.min(560, fs * 18)}>
        <div style={{display: 'flex', flexDirection: 'column', gap: 8}}>
          <Typewriter text="$ sprint complete" frame={frame} start={5} cps={14} fs={fs} />
          <div style={{opacity: fadeIn(frame, 35, 20), fontFamily: MONO, fontSize: fs, color: GREEN}}>
            t-0d3b: closed
          </div>
          <div style={{opacity: fadeIn(frame, 50, 20), fontFamily: MONO, fontSize: fs, color: GREEN}}>
            Sprint completed: t-0d3b ✓
          </div>
        </div>
      </TerminalWindow>
      <Caption text="Closed." frame={frame} showAt={60} fs={capFs} />
    </AbsoluteFill>
  );
};

// ─── Scene 7: Board + CTA (810–960f, local 0–150) ────────────────────────────

const SceneBoard: React.FC<{fs: number; capFs: number; width: number; height: number}> = ({fs, capFs, width, height}) => {
  const frame = useCurrentFrame();
  const boardSp = useSpring(frame, 10);
  const boardScale = interpolate(boardSp, [0, 1], [0.92, 1]);
  const boardOpacity = fadeIn(frame, 5, 25);
  const ctaOpacity = fadeIn(frame, 80, 25);
  // Scale image to fill ~60% of content height, constrained by width
  const imgByHeight = height * 0.58;
  const imgByWidth = width * 0.9;
  const imgW = Math.min(imgByWidth, imgByHeight * 1.78); // board is ~16:9 screenshot

  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', flexDirection: 'column', gap: 24}}>
      <div style={{
        opacity: boardOpacity,
        transform: `scale(${boardScale})`,
        borderRadius: 12,
        overflow: 'hidden',
        border: `1px solid ${BORDER}`,
        boxShadow: `0 24px 80px rgba(0,0,0,0.6)`,
      }}>
        <Img src={staticFile('board.png')} style={{width: imgW, display: 'block'}} />
      </div>

      <div style={{
        opacity: fadeIn(frame, 50, 20),
        fontFamily: MONO,
        fontSize: fs * 0.8,
        color: MUTED,
        textAlign: 'center',
      }}>
        Every sprint. Its own receipt.
      </div>

      <div style={{
        opacity: ctaOpacity,
        background: CARD,
        border: `1px solid ${BLUE}55`,
        borderRadius: 8,
        padding: '10px 24px',
        display: 'flex',
        alignItems: 'center',
        gap: 12,
      }}>
        <span style={{fontSize: fs * 0.85, color: BLUE}}>★</span>
        <span style={{fontFamily: MONO, fontSize: fs * 0.8, color: TEXT}}>
          github.com/sunitghub/canon-skills
        </span>
      </div>
    </AbsoluteFill>
  );
};

// ─── Main composition ─────────────────────────────────────────────────────────

interface CanonReelProps {
  aspectRatio: '9:16' | '16:9';
}

export const CanonReel: React.FC<CanonReelProps> = ({aspectRatio}) => {
  const {width, height} = useVideoConfig();
  const is916 = aspectRatio === '9:16';

  // Scale fonts relative to width
  const fs   = Math.round(width * 0.033);   // ~36px @ 1080
  const capFs = Math.round(width * 0.028);  // ~30px @ 1080
  const termW = Math.min(width * 0.82, 860);
  const barH  = is916 ? 158 : 130;
  const barFs = Math.round(width * 0.012);  // pipeline labels

  const contentH = height - barH;

  return (
    <AbsoluteFill style={{background: BG, fontFamily: MONO}}>
      {/* Content area */}
      <div style={{position: 'absolute', top: 0, left: 0, right: 0, height: contentH, overflow: 'hidden'}}>
        <Sequence from={SCENES.HOOK.start}  durationInFrames={SCENES.HOOK.dur}>
          <SceneHook fs={fs} termW={termW} />
        </Sequence>
        <Sequence from={SCENES.PLAN.start}  durationInFrames={SCENES.PLAN.dur}>
          <ScenePlan fs={fs} capFs={capFs} />
        </Sequence>
        <Sequence from={SCENES.GATE1.start} durationInFrames={SCENES.GATE1.dur}>
          <SceneGateApproved fs={fs} capFs={capFs} />
        </Sequence>
        <Sequence from={SCENES.BUILD.start} durationInFrames={SCENES.BUILD.dur}>
          <SceneBuild fs={fs} />
        </Sequence>
        <Sequence from={SCENES.GATE2.start} durationInFrames={SCENES.GATE2.dur}>
          <SceneGateBlocked fs={fs} capFs={capFs} />
        </Sequence>
        <Sequence from={SCENES.CLOSE.start} durationInFrames={SCENES.CLOSE.dur}>
          <SceneClose fs={fs} capFs={capFs} />
        </Sequence>
        <Sequence from={SCENES.BOARD.start} durationInFrames={SCENES.BOARD.dur}>
          <SceneBoard fs={fs} capFs={capFs} width={width} height={contentH} />
        </Sequence>
      </div>

      {/* Pipeline bar — always visible */}
      <div style={{position: 'absolute', bottom: 0, left: 0, right: 0, height: barH}}>
        <PipelineBar barHeight={barH} fontSize={barFs} />
      </div>
    </AbsoluteFill>
  );
};
