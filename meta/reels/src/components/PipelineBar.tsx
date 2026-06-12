import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {BLUE, GREEN, RED, MUTED, BG, TEXT, BORDER, FPS, SCENES} from '../constants';

type NodeState = 'inactive' | 'active' | 'gate-pending' | 'gate-pass' | 'gate-fail';

interface PipelineNode {
  label: string;
  sublabel: string;
  isGate: boolean;
  activateFrame: number;
  passFrame?: number;
  failFrame?: number;
  resolveFrame?: number;
}

const NODES: PipelineNode[] = [
  {label: 'Plan', sublabel: 'ticket · acceptance · plan.md', isGate: false, activateFrame: 0},
  {label: 'GATE', sublabel: 'user approves', isGate: true, activateFrame: SCENES.GATE1.start, passFrame: SCENES.GATE1.start + 30},
  {label: 'Build', sublabel: 'code · commits', isGate: false, activateFrame: SCENES.BUILD.start},
  {label: 'GATE', sublabel: 'all ✓ · summary.md', isGate: true, activateFrame: SCENES.GATE2.start, failFrame: SCENES.GATE2.start, resolveFrame: SCENES.GATE2.start + 75},
  {label: 'Close', sublabel: 'sprint complete', isGate: false, activateFrame: SCENES.CLOSE.start},
  {label: 'Board', sublabel: 'sprint-check', isGate: false, activateFrame: SCENES.BOARD.start},
];

function nodeState(node: PipelineNode, frame: number): NodeState {
  if (frame < node.activateFrame) return 'inactive';
  if (node.isGate) {
    if (node.failFrame !== undefined && node.resolveFrame !== undefined) {
      if (frame >= node.failFrame && frame < node.resolveFrame) return 'gate-fail';
      if (frame >= node.resolveFrame) return 'gate-pass';
      return 'gate-pending';
    }
    if (node.passFrame !== undefined && frame >= node.passFrame) return 'gate-pass';
    return 'gate-pending';
  }
  return 'active';
}

function nodeColor(state: NodeState): string {
  switch (state) {
    case 'active': return BLUE;
    case 'gate-pass': return GREEN;
    case 'gate-fail': return RED;
    case 'gate-pending': return BLUE;
    case 'inactive': return BORDER;
  }
}

export const PipelineBar: React.FC<{barHeight: number; fontSize: number}> = ({barHeight, fontSize}) => {
  const frame = useCurrentFrame();

  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      height: barHeight,
      background: BG,
      borderTop: `1px solid ${BORDER}`,
      padding: '0 24px',
      gap: 0,
    }}>
      {NODES.map((node, i) => {
        const state = nodeState(node, frame);
        const color = nodeColor(state);
        const opacity = state === 'inactive' ? 0.35 : 1;

        // Shake gate-fail node
        const shakeOffset = (state === 'gate-fail')
          ? interpolate(
              (frame - (node.failFrame ?? 0)) % 8,
              [0, 2, 4, 6, 8],
              [0, -4, 4, -4, 0],
              {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}
            )
          : 0;

        const isGateNode = node.isGate;

        return (
          <React.Fragment key={i}>
            {/* Node */}
            <div style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              opacity,
              transform: `translateX(${shakeOffset}px)`,
              minWidth: isGateNode ? 80 : 130,
            }}>
              <div style={{
                border: `2px solid ${color}`,
                borderRadius: isGateNode ? 4 : 6,
                padding: isGateNode ? '4px 10px' : '5px 12px',
                background: state !== 'inactive' ? `${color}18` : 'transparent',
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                minWidth: isGateNode ? 72 : 110,
              }}>
                <span style={{
                  fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
                  fontSize: isGateNode ? fontSize * 0.85 : fontSize,
                  fontWeight: 700,
                  color: state !== 'inactive' ? color : MUTED,
                  letterSpacing: isGateNode ? 1 : 0,
                }}>
                  {state === 'gate-pass' ? '✓' : state === 'gate-fail' ? '✗' : node.label}
                </span>
                {!isGateNode && (
                  <span style={{
                    fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
                    fontSize: fontSize * 0.62,
                    color: state !== 'inactive' ? `${color}cc` : MUTED,
                    marginTop: 2,
                    textAlign: 'center',
                    whiteSpace: 'nowrap',
                  }}>
                    {node.sublabel}
                  </span>
                )}
              </div>
            </div>

            {/* Arrow between nodes */}
            {i < NODES.length - 1 && (
              <div style={{
                flex: 1,
                height: 2,
                background: frame >= NODES[i + 1].activateFrame ? BLUE : BORDER,
                opacity: frame >= NODES[i + 1].activateFrame ? 0.6 : 0.25,
                margin: '0 4px',
                position: 'relative',
              }}>
                <span style={{
                  position: 'absolute',
                  right: -6,
                  top: '50%',
                  transform: 'translateY(-50%)',
                  color: frame >= NODES[i + 1].activateFrame ? BLUE : BORDER,
                  opacity: frame >= NODES[i + 1].activateFrame ? 0.6 : 0.25,
                  fontSize: fontSize * 0.9,
                  lineHeight: 1,
                }}>›</span>
              </div>
            )}
          </React.Fragment>
        );
      })}
    </div>
  );
};
