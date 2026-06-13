import React from 'react';
import {ComponentType} from 'react';
import {Composition} from 'remotion';
import {CanonReel, TOTAL_FRAMES, FPS} from './CanonReel';
import {CanonTodoCaptioned, TOTAL_FRAMES as TODO_FRAMES} from './CanonTodoCaptioned';

// Remotion expects component props to extend Record<string,unknown>
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const C = CanonReel as ComponentType<any>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const TodoC = CanonTodoCaptioned as ComponentType<any>;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="CanonReel9x16"
        component={C}
        durationInFrames={TOTAL_FRAMES}
        fps={FPS}
        width={1080}
        height={1920}
        defaultProps={{aspectRatio: '9:16'}}
      />
      <Composition
        id="CanonReel16x9"
        component={C}
        durationInFrames={TOTAL_FRAMES}
        fps={FPS}
        width={1920}
        height={1080}
        defaultProps={{aspectRatio: '16:9'}}
      />
      <Composition
        id="CanonTodoCaptioned"
        component={TodoC}
        durationInFrames={TODO_FRAMES}
        fps={30}
        width={2050}
        height={1522}
        defaultProps={{}}
      />
    </>
  );
};
