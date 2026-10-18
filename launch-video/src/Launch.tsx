import { Audio } from "@remotion/media";
import { TransitionSeries, linearTiming } from "@remotion/transitions";
import type { TransitionPresentation, TransitionPresentationComponentProps } from "@remotion/transitions";
import type React from "react";
import { AbsoluteFill, Easing, Sequence, interpolate, staticFile, useVideoConfig } from "remotion";
import { Coin, Files, Intro, Market, Messaging, More, Outro, PeerToPeer, Privacy, Title } from "./scenes";
import "./theme";

// A snappy zoom-through: the old scene rushes past the camera while the
// new one settles in from slightly behind.
const ZoomThrough: React.FC<TransitionPresentationComponentProps<Record<string, never>>> = ({
  children,
  presentationDirection,
  presentationProgress: p,
}) => {
  const e = Easing.bezier(0.7, 0, 0.3, 1)(p);
  const exiting = presentationDirection === "exiting";
  return (
    <AbsoluteFill
      style={{
        opacity: exiting ? 1 - e : interpolate(e, [0, 0.5], [0, 1], { extrapolateRight: "clamp" }),
        scale: String(exiting ? 1 + e * 0.35 : 0.88 + e * 0.12),
        filter: `blur(${exiting ? e * 24 : (1 - e) * 16}px)`,
      }}
    >
      {children}
    </AbsoluteFill>
  );
};

const zoomThrough = (): TransitionPresentation<Record<string, never>> => ({ component: ZoomThrough, props: {} });

export const T = 12; // transition length in frames

export const SCENES = [
  { name: "Intro", component: Intro, seconds: 3.6 },
  { name: "Title", component: Title, seconds: 3.4 },
  { name: "Peer to peer", component: PeerToPeer, seconds: 5.2 },
  { name: "Messaging", component: Messaging, seconds: 4.6 },
  { name: "Privacy", component: Privacy, seconds: 4.2 },
  { name: "Coin", component: Coin, seconds: 5.8 },
  { name: "Files", component: Files, seconds: 4.8 },
  { name: "Market", component: Market, seconds: 5.8 },
  { name: "More", component: More, seconds: 5.4 },
  { name: "Outro", component: Outro, seconds: 4.5 },
] as const;

export const launchDuration = (fps: number) =>
  SCENES.reduce((sum, s) => sum + Math.round(s.seconds * fps), 0) - T * (SCENES.length - 1);

export const Launch: React.FC = () => {
  const { fps } = useVideoConfig();
  let at = 0;
  const cuts: number[] = [];
  SCENES.forEach((s, i) => {
    at += Math.round(s.seconds * fps) - (i < SCENES.length - 1 ? T : 0);
    if (i < SCENES.length - 1) cuts.push(at);
  });
  return (
    <AbsoluteFill style={{ backgroundColor: "#050706" }}>
      <TransitionSeries>
        {SCENES.flatMap((s, i) => {
          const Scene = s.component;
          const seq = (
            <TransitionSeries.Sequence key={s.name} name={s.name} durationInFrames={Math.round(s.seconds * fps)}>
              <Scene />
            </TransitionSeries.Sequence>
          );
          return i < SCENES.length - 1
            ? [seq, <TransitionSeries.Transition key={`${s.name}-t`} presentation={zoomThrough()} timing={linearTiming({ durationInFrames: T })} />]
            : [seq];
        })}
      </TransitionSeries>
      <Sequence name="Riser" durationInFrames={4 * fps}>
        <Audio src={staticFile("sfx/whoosh.wav")} volume={0.5} />
      </Sequence>
      {cuts.map((c) => (
        <Sequence key={c} name="Whoosh" from={c - 6} durationInFrames={2 * fps}>
          <Audio src={staticFile("sfx/whip.wav")} volume={0.35} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
