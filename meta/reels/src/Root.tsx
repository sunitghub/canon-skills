import React from 'react';
import {ComponentType} from 'react';
import {Composition} from 'remotion';
import {CanonReel, TOTAL_FRAMES, FPS} from './CanonReel';

// Remotion expects component props to extend Record<string,unknown>
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const C = CanonReel as ComponentType<any>;

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
    </>
  );
};
