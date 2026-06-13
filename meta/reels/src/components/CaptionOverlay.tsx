import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';

export interface Caption {
  text: string;
  startFrame: number;
  endFrame: number;
}

const FADE = 8; // frames to fade in/out

export const CaptionOverlay: React.FC<{captions: Caption[]}> = ({captions}) => {
  const frame = useCurrentFrame();

  const active = captions.find((c) => frame >= c.startFrame && frame < c.endFrame);
  if (!active) return null;

  const local = frame - active.startFrame;
  const dur = active.endFrame - active.startFrame;

  const opacity = interpolate(
    local,
    [0, FADE, dur - FADE, dur],
    [0, 1, 1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );

  const translateY = interpolate(local, [0, FADE], [10, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill style={{justifyContent: 'flex-end', alignItems: 'center', pointerEvents: 'none'}}>
      <div
        style={{
          marginBottom: 48,
          opacity,
          transform: `translateY(${translateY}px)`,
          background: 'rgba(0,0,0,0.62)',
          borderRadius: 12,
          padding: '14px 32px',
          maxWidth: '88%',
          textAlign: 'center',
        }}
      >
        <span
          style={{
            fontFamily: "'Inter', 'Helvetica Neue', sans-serif",
            fontSize: 36,
            fontWeight: 600,
            color: '#ffffff',
            lineHeight: 1.4,
            letterSpacing: '-0.3px',
            textShadow: '0 1px 6px rgba(0,0,0,0.5)',
          }}
        >
          {active.text}
        </span>
      </div>
    </AbsoluteFill>
  );
};
