import React from 'react';
import {AbsoluteFill, OffthreadVideo, staticFile, useVideoConfig} from 'remotion';
import {CaptionOverlay, Caption} from './components/CaptionOverlay';

const FPS = 30;

// Source segments (after the cut):
//   0  –  7.5s  seg1: skills.sh add sprint (2x)
//   7.5 – 22.5s seg2: Codex working (4x)
//  22.5 – 64.7s seg3: board live + acceptance modal (1x)

const f = (s: number) => Math.round(s * FPS);

const CAPTIONS: Caption[] = [
  {
    text: 'One command wires your agent to your repo',
    startFrame: f(0.5),
    endFrame: f(7),
  },
  {
    text: 'sprint start — plan drafted, ticket created, acceptance criteria set',
    startFrame: f(8),
    endFrame: f(22),
  },
  {
    text: 'Board updates live as the agent works',
    startFrame: f(23),
    endFrame: f(38),
  },
  {
    text: 'Plan, criteria, delivery receipt — all in your repo',
    startFrame: f(39),
    endFrame: f(63),
  },
];

export const TOTAL_FRAMES = f(64.7);

export const CanonTodoCaptioned: React.FC = () => {
  const {width, height} = useVideoConfig();

  return (
    <AbsoluteFill style={{background: '#000'}}>
      <OffthreadVideo
        src={staticFile('canon-todo-60s.mp4')}
        style={{width, height, objectFit: 'contain'}}
      />
      <CaptionOverlay captions={CAPTIONS} />
    </AbsoluteFill>
  );
};
