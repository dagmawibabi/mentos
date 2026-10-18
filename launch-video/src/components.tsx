import type React from "react";
import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  random,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { C, MONO, SANS } from "./theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
export const easeOut = Easing.bezier(0.16, 1, 0.3, 1);

/** Snappy spring from 0 to 1 starting at [delay] frames. */
export const useSpringIn = (delay = 0, damping = 18, mass = 0.6) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({ frame: frame - delay, fps, config: { damping, mass, stiffness: 140 } });
};

// ---------------------------------------------------------------------------
// Backdrop: deep ink, perspective grid drifting toward the viewer, a slow
// emerald aurora and a faint vignette.
// ---------------------------------------------------------------------------
export const Backdrop: React.FC<{ glowX?: number; glowY?: number; hue?: string }> = ({
  glowX = 50,
  glowY = 40,
  hue = C.accent,
}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ backgroundColor: C.bg, overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(circle at ${glowX + Math.sin(frame / 50) * 4}% ${glowY + Math.cos(frame / 60) * 3}%, ${hue}26 0%, transparent 45%)`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: "-50%",
          right: "-50%",
          top: "52%",
          height: "120%",
          transform: "perspective(900px) rotateX(72deg)",
          transformOrigin: "50% 0%",
          backgroundImage: `linear-gradient(${C.accent}22 1px, transparent 1px), linear-gradient(90deg, ${C.accent}22 1px, transparent 1px)`,
          backgroundSize: "80px 80px",
          backgroundPosition: `0px ${(frame * 2) % 80}px`,
          maskImage: "linear-gradient(to bottom, transparent 0%, black 25%, black 60%, transparent 100%)",
          WebkitMaskImage: "linear-gradient(to bottom, transparent 0%, black 25%, black 60%, transparent 100%)",
        }}
      />
      <Dust />
      <AbsoluteFill
        style={{ background: "radial-gradient(ellipse at center, transparent 55%, rgba(0,0,0,0.75) 100%)" }}
      />
    </AbsoluteFill>
  );
};

const Dust: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  return (
    <svg width={width} height={height} style={{ position: "absolute", inset: 0 }}>
      {new Array(60).fill(0).map((_, i) => {
        const x = random(`dx${i}`) * width;
        const speed = 0.2 + random(`ds${i}`) * 0.6;
        const y = (random(`dy${i}`) * height - frame * speed + height) % height;
        const r = 0.6 + random(`dr${i}`) * 1.6;
        const o = 0.15 + random(`do${i}`) * 0.4;
        return <circle key={i} cx={x} cy={y} r={r} fill={C.accent} opacity={o} />;
      })}
    </svg>
  );
};

// ---------------------------------------------------------------------------
// Mesh: a peer-to-peer network that wires itself up, with packets hopping
// along the links.
// ---------------------------------------------------------------------------
export const Mesh: React.FC<{
  nodes?: number;
  seed?: string;
  start?: number;
  opacity?: number;
  linkDist?: number;
}> = ({ nodes = 34, seed = "mesh", start = 0, opacity = 1, linkDist = 330 }) => {
  const frame = useCurrentFrame() - start;
  const { width, height } = useVideoConfig();
  const pts = new Array(nodes).fill(0).map((_, i) => ({
    x: 120 + random(`${seed}x${i}`) * (width - 240) + Math.sin((frame + i * 40) / 45) * 8,
    y: 100 + random(`${seed}y${i}`) * (height - 200) + Math.cos((frame + i * 30) / 50) * 8,
    t: Math.floor(random(`${seed}t${i}`) * 30),
  }));
  const links: Array<[number, number, number]> = [];
  for (let a = 0; a < pts.length; a++) {
    for (let b = a + 1; b < pts.length; b++) {
      const d = Math.hypot(pts[a].x - pts[b].x, pts[a].y - pts[b].y);
      if (d < linkDist) links.push([a, b, d]);
    }
  }
  return (
    <svg width={width} height={height} style={{ position: "absolute", inset: 0, opacity }}>
      <defs>
        <filter id={`${seed}-glow`} x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="4" result="b" />
          <feMerge>
            <feMergeNode in="b" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>
      {links.map(([a, b, d], i) => {
        const begin = Math.max(pts[a].t, pts[b].t) + 6;
        const p = interpolate(frame, [begin, begin + 18], [0, 1], { ...clamp, easing: easeOut });
        const x2 = pts[a].x + (pts[b].x - pts[a].x) * p;
        const y2 = pts[a].y + (pts[b].y - pts[a].y) * p;
        return (
          <line
            key={`l${i}`}
            x1={pts[a].x}
            y1={pts[a].y}
            x2={x2}
            y2={y2}
            stroke={C.accent}
            strokeOpacity={0.12 + (1 - d / linkDist) * 0.3}
            strokeWidth={1.2}
          />
        );
      })}
      {links
        .filter((_, i) => i % 3 === 0)
        .map(([a, b], i) => {
          const period = 40 + Math.floor(random(`${seed}p${i}`) * 40);
          const off = Math.floor(random(`${seed}o${i}`) * period);
          const q = ((frame + off) % period) / period;
          const live = frame > Math.max(pts[a].t, pts[b].t) + 24;
          if (!live) return null;
          return (
            <circle
              key={`p${i}`}
              cx={pts[a].x + (pts[b].x - pts[a].x) * q}
              cy={pts[a].y + (pts[b].y - pts[a].y) * q}
              r={3}
              fill={C.accent}
              filter={`url(#${seed}-glow)`}
              opacity={Math.sin(q * Math.PI)}
            />
          );
        })}
      {pts.map((p, i) => {
        const s = interpolate(frame, [p.t, p.t + 10], [0, 1], { ...clamp, easing: easeOut });
        return (
          <g key={`n${i}`}>
            <circle cx={p.x} cy={p.y} r={14 * s} fill={C.accent} opacity={0.08} />
            <circle cx={p.x} cy={p.y} r={4.5 * s} fill={i % 5 === 0 ? C.accent : C.ink} filter={`url(#${seed}-glow)`} />
          </g>
        );
      })}
    </svg>
  );
};

// ---------------------------------------------------------------------------
// The Mentos mark, the three linked nodes from the app's header.
// ---------------------------------------------------------------------------
export const Mark: React.FC<{ size?: number; progress?: number }> = ({ size = 160, progress = 1 }) => {
  const draw = interpolate(progress, [0, 0.6], [0, 1], clamp);
  const dots = interpolate(progress, [0.3, 1], [0, 1], clamp);
  return (
    <svg width={size} height={size} viewBox="0 0 100 100">
      <defs>
        <filter id="markglow" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="3" result="b" />
          <feMerge>
            <feMergeNode in="b" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>
      <path
        d="M50 22 L24 76 M50 22 L76 76"
        stroke={C.ink}
        strokeWidth={8}
        strokeLinecap="round"
        fill="none"
        pathLength={1}
        strokeDasharray={1}
        strokeDashoffset={1 - draw}
      />
      <circle cx={50} cy={22} r={13 * dots} fill={C.accent} filter="url(#markglow)" />
      <circle cx={24} cy={78} r={13 * dots} fill={C.ink} />
      <circle cx={76} cy={78} r={13 * dots} fill={C.ink} />
    </svg>
  );
};

// ---------------------------------------------------------------------------
// Phone: a device frame around a real capture of the app.
// ---------------------------------------------------------------------------
export const Phone: React.FC<{
  src: string;
  height?: number;
  style?: React.CSSProperties;
  glow?: number;
  /** 0..1, scrolls the capture inside the screen. */
  scroll?: number;
  zoom?: number;
}> = ({ src, height = 820, style, glow = 1, scroll = 0, zoom = 1 }) => {
  const w = (height * 1170) / 2532;
  const bezel = height * 0.018;
  return (
    <div
      style={{
        position: "absolute",
        width: w + bezel * 2,
        height: height + bezel * 2,
        borderRadius: height * 0.075,
        padding: bezel,
        background: "linear-gradient(145deg, #2a302d 0%, #0d100f 45%, #1d2220 100%)",
        boxShadow: `0 0 0 1.5px #3a423e inset, 0 40px 120px rgba(0,0,0,0.7), 0 0 ${120 * glow}px ${C.accent}${glow > 0 ? "30" : "00"}`,
        ...style,
      }}
    >
      <div
        style={{
          width: w,
          height,
          borderRadius: height * 0.062,
          overflow: "hidden",
          position: "relative",
          backgroundColor: "#000",
        }}
      >
        <Img
          src={src}
          style={{
            width: "100%",
            display: "block",
            scale: String(zoom),
            transformOrigin: "50% 0%",
            translate: `0px ${-scroll * height * 0.25}px`,
          }}
        />
        <div
          style={{
            position: "absolute",
            inset: 0,
            background: "linear-gradient(115deg, rgba(255,255,255,0.10) 0%, rgba(255,255,255,0) 32%)",
            pointerEvents: "none",
          }}
        />
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------
export const Kicker: React.FC<{ children: string; delay?: number; style?: React.CSSProperties }> = ({
  children,
  delay = 0,
  style,
}) => {
  const frame = useCurrentFrame();
  const shown = Math.floor(interpolate(frame - delay, [0, 16], [0, children.length], clamp));
  const o = interpolate(frame - delay, [0, 4], [0, 1], clamp);
  return (
    <div
      style={{
        fontFamily: MONO,
        fontSize: 26,
        letterSpacing: 6,
        color: C.accent,
        textTransform: "uppercase",
        opacity: o,
        display: "flex",
        alignItems: "center",
        gap: 16,
        ...style,
      }}
    >
      <span
        style={{
          width: 10,
          height: 10,
          borderRadius: 5,
          backgroundColor: C.accent,
          boxShadow: `0 0 16px ${C.accent}`,
        }}
      />
      {children.slice(0, shown)}
      <span style={{ opacity: frame % 16 < 8 && shown < children.length + 1 ? 1 : 0 }}>_</span>
    </div>
  );
};

/** Words rise out of a blur, one after another. */
export const Headline: React.FC<{
  text: string;
  delay?: number;
  size?: number;
  accent?: string[];
  style?: React.CSSProperties;
  stagger?: number;
}> = ({ text, delay = 0, size = 92, accent = [], style, stagger = 3 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const lines = text.split("\n");
  let index = 0;
  return (
    <div
      style={{
        fontFamily: SANS,
        fontWeight: 600,
        fontSize: size,
        lineHeight: 1.04,
        letterSpacing: -size * 0.035,
        color: C.ink,
        ...style,
      }}
    >
      {lines.map((line, li) => (
        <div key={li} style={{ display: "flex", flexWrap: "wrap", columnGap: size * 0.26 }}>
          {line.split(" ").map((word) => {
            const i = index++;
            const s = spring({
              frame: frame - delay - i * stagger,
              fps,
              config: { damping: 20, mass: 0.5, stiffness: 160 },
            });
            const isAccent = accent.includes(word.replace(/[.,!?]/g, ""));
            return (
              <span
                key={i}
                style={{
                  display: "inline-block",
                  opacity: s,
                  translate: `0px ${(1 - s) * size * 0.5}px`,
                  filter: `blur(${(1 - s) * 14}px)`,
                  color: isAccent ? C.accent : undefined,
                  textShadow: isAccent ? `0 0 40px ${C.accent}66` : undefined,
                }}
              >
                {word}
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

export const Body: React.FC<{ children: React.ReactNode; delay?: number; style?: React.CSSProperties }> = ({
  children,
  delay = 0,
  style,
}) => {
  const s = useSpringIn(delay);
  return (
    <div
      style={{
        fontFamily: SANS,
        fontSize: 38,
        lineHeight: 1.35,
        color: C.muted,
        opacity: s,
        translate: `0px ${(1 - s) * 24}px`,
        ...style,
      }}
    >
      {children}
    </div>
  );
};

/** Mono spec lines with a leading tick, like a terminal readout. */
export const Specs: React.FC<{ items: string[]; delay?: number; style?: React.CSSProperties }> = ({
  items,
  delay = 0,
  style,
}) => {
  const frame = useCurrentFrame();
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 18, ...style }}>
      {items.map((item, i) => {
        const t = frame - delay - i * 6;
        const o = interpolate(t, [0, 8], [0, 1], clamp);
        const chars = Math.floor(interpolate(t, [0, 14], [0, item.length], clamp));
        return (
          <div
            key={item}
            style={{
              fontFamily: MONO,
              fontSize: 30,
              color: C.inkSoft,
              opacity: o,
              display: "flex",
              gap: 18,
              alignItems: "center",
            }}
          >
            <span style={{ color: C.accent }}>{"›"}</span>
            {item.slice(0, chars)}
          </div>
        );
      })}
    </div>
  );
};

export const Chip: React.FC<{ label: string; active?: boolean; style?: React.CSSProperties }> = ({
  label,
  active,
  style,
}) => (
  <div
    style={{
      fontFamily: SANS,
      fontWeight: 500,
      fontSize: 30,
      padding: "14px 28px",
      borderRadius: 999,
      border: `1.5px solid ${active ? C.accent : C.line}`,
      color: active ? C.accent : C.inkSoft,
      backgroundColor: active ? `${C.accent}1A` : `${C.surface}cc`,
      boxShadow: active ? `0 0 30px ${C.accent}44` : "none",
      ...style,
    }}
  >
    {label}
  </div>
);

/** A thin scanning light sweep across the frame, used on reveals. */
export const Sweep: React.FC<{ at: number; duration?: number }> = ({ at, duration = 18 }) => {
  const frame = useCurrentFrame();
  const p = interpolate(frame, [at, at + duration], [-0.3, 1.3], clamp);
  if (p <= -0.3 || p >= 1.3) return null;
  return (
    <AbsoluteFill
      style={{
        background: `linear-gradient(100deg, transparent ${p * 100 - 12}%, ${C.accent}22 ${p * 100}%, transparent ${p * 100 + 12}%)`,
        pointerEvents: "none",
      }}
    />
  );
};
