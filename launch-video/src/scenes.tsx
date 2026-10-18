import type React from "react";
import { AbsoluteFill, Easing, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import {
  Backdrop,
  Body,
  Chip,
  Headline,
  Kicker,
  Mark,
  Mesh,
  Phone,
  Specs,
  Sweep,
  easeOut,
  useSpringIn,
} from "./components";
import { C, MONO, SANS, screen } from "./theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** Slow push-in shared by every scene so nothing is ever static. */
const usePush = (from = 1, to = 1.04) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  return interpolate(frame, [0, durationInFrames], [from, to], clamp);
};

/** Phone that springs up from below with a 3D tilt that settles. */
const FloatingPhone: React.FC<{
  src: string;
  delay?: number;
  x: number;
  y: number;
  height?: number;
  rotY?: number;
  rotZ?: number;
  glow?: number;
  scroll?: number;
  zoom?: number;
  z?: number;
}> = ({ src, delay = 0, x, y, height = 820, rotY = 0, rotZ = 0, glow = 1, scroll = 0, zoom = 1, z = 0 }) => {
  const frame = useCurrentFrame();
  const s = useSpringIn(delay, 16, 0.7);
  const bob = Math.sin((frame + delay * 7) / 28) * 8;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        zIndex: z,
        transform: `perspective(2200px) translateY(${(1 - s) * 500 + bob}px) rotateY(${rotY + (1 - s) * 25}deg) rotateZ(${rotZ * s}deg) scale(${0.85 + s * 0.15})`,
        opacity: interpolate(s, [0, 0.3], [0, 1], clamp),
      }}
    >
      <Phone src={src} height={height} glow={glow} scroll={scroll} zoom={zoom} style={{ position: "relative" }} />
    </div>
  );
};

// ---------------------------------------------------------------------------
// 1. Cold open: a mesh wires itself up while the claims land hard.
// ---------------------------------------------------------------------------
export const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const lines = [
    { t: 8, text: "No servers." },
    { t: 34, text: "No accounts." },
    { t: 58, text: "No middlemen." },
  ];
  const finalIn = 82;
  return (
    <AbsoluteFill>
      <Backdrop />
      <Mesh nodes={42} seed="intro" opacity={interpolate(frame, [0, 20], [0.35, 0.9], clamp)} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        {lines.map((l, i) => {
          const next = lines[i + 1]?.t ?? finalIn;
          if (frame < l.t || frame >= next) return null;
          const local = frame - l.t;
          return (
            <div
              key={l.text}
              style={{
                fontFamily: SANS,
                fontWeight: 600,
                fontSize: 170,
                letterSpacing: -6,
                color: C.ink,
                scale: String(interpolate(local, [0, 26], [1.12, 1], { ...clamp, easing: easeOut })),
                filter: `blur(${interpolate(local, [0, 6], [18, 0], clamp)}px)`,
                opacity: interpolate(local, [0, 4], [0, 1], clamp),
                textShadow: "0 10px 60px rgba(0,0,0,0.8)",
              }}
            >
              {l.text}
            </div>
          );
        })}
        {frame >= finalIn ? (
          <div
            style={{
              fontFamily: SANS,
              fontWeight: 600,
              fontSize: 190,
              letterSpacing: -7,
              color: C.accent,
              textShadow: `0 0 80px ${C.accent}88`,
              scale: String(interpolate(frame - finalIn, [0, 20], [0.9, 1], { ...clamp, easing: easeOut })),
              opacity: interpolate(frame - finalIn, [0, 5], [0, 1], clamp),
            }}
          >
            Just phones.
          </div>
        ) : null}
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 2. Title: the mark and the wordmark.
// ---------------------------------------------------------------------------
export const Title: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const mark = spring({ frame, fps, config: { damping: 14, mass: 0.8 } });
  const word = "Mentos";
  const ring = interpolate(frame, [4, 40], [0, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  return (
    <AbsoluteFill style={{ scale: String(usePush(1, 1.05)) }}>
      <Backdrop glowY={45} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div
          style={{
            position: "absolute",
            width: 900 * ring,
            height: 900 * ring,
            borderRadius: "50%",
            border: `2px solid ${C.accent}`,
            opacity: 1 - ring,
          }}
        />
        <div style={{ display: "flex", alignItems: "center", gap: 48 }}>
          <div style={{ scale: String(0.4 + mark * 0.6), rotate: `${(1 - mark) * -40}deg` }}>
            <Mark size={220} progress={interpolate(frame, [0, 28], [0, 1], clamp)} />
          </div>
          <div style={{ display: "flex", fontFamily: SANS, fontWeight: 600, fontSize: 240, letterSpacing: -10 }}>
            {word.split("").map((ch, i) => {
              const s = spring({ frame: frame - 8 - i * 2, fps, config: { damping: 18, mass: 0.5 } });
              return (
                <span
                  key={i}
                  style={{
                    display: "inline-block",
                    color: C.ink,
                    opacity: s,
                    translate: `0px ${(1 - s) * 120}px`,
                    filter: `blur(${(1 - s) * 16}px)`,
                  }}
                >
                  {ch}
                </span>
              );
            })}
          </div>
        </div>
        <Body delay={30} style={{ marginTop: 40, fontSize: 48, color: C.inkSoft, textAlign: "center" }}>
          The social network that lives on your phone.
        </Body>
        <div
          style={{
            marginTop: 34,
            fontFamily: MONO,
            fontSize: 28,
            letterSpacing: 8,
            color: C.accent,
            opacity: interpolate(frame, [44, 56], [0, 1], clamp),
          }}
        >
          PEER-TO-PEER · ENCRYPTED · SERVERLESS
        </div>
      </AbsoluteFill>
      <Sweep at={10} duration={26} />
    </AbsoluteFill>
  );
};

/** Left column copy used by the feature scenes. */
const Copy: React.FC<{
  kicker: string;
  title: string;
  accent: string[];
  body?: string;
  specs?: string[];
  width?: number;
  left?: number;
  children?: React.ReactNode;
}> = ({ kicker, title, accent, body, specs, width = 820, left = 130, children }) => (
  <div style={{ position: "absolute", left, top: 0, bottom: 0, width, display: "flex", flexDirection: "column", justifyContent: "center", gap: 34 }}>
    <Kicker delay={2}>{kicker}</Kicker>
    <Headline text={title} accent={accent} delay={6} size={104} />
    {body ? <Body delay={18}>{body}</Body> : null}
    {specs ? <Specs items={specs} delay={26} style={{ marginTop: 8 }} /> : null}
    {children}
  </div>
);

/** Glowing links between phones, with packets travelling across them. */
const Links: React.FC<{ points: Array<[number, number]>; start?: number }> = ({ points, start = 20 }) => {
  const frame = useCurrentFrame() - start;
  const { width, height } = useVideoConfig();
  return (
    <svg width={width} height={height} style={{ position: "absolute", inset: 0, zIndex: 5, pointerEvents: "none" }}>
      {points.slice(1).map((b, i) => {
        const a = points[i];
        const p = interpolate(frame, [i * 6, i * 6 + 16], [0, 1], { ...clamp, easing: easeOut });
        const mx = (a[0] + b[0]) / 2;
        const my = Math.min(a[1], b[1]) - 120;
        const d = `M${a[0]} ${a[1]} Q${mx} ${my} ${b[0]} ${b[1]}`;
        return (
          <g key={i}>
            <path d={d} stroke={C.accent} strokeWidth={2.5} fill="none" pathLength={1} strokeDasharray="1" strokeDashoffset={1 - p} opacity={0.8} />
            {[0, 0.33, 0.66].map((o) => {
              const q = ((frame / 34 + o) % 1 + 1) % 1;
              const x = (1 - q) * (1 - q) * a[0] + 2 * (1 - q) * q * mx + q * q * b[0];
              const y = (1 - q) * (1 - q) * a[1] + 2 * (1 - q) * q * my + q * q * b[1];
              return p >= 1 ? <circle key={o} cx={x} cy={y} r={7} fill={C.accent} style={{ filter: `drop-shadow(0 0 10px ${C.accent})` }} /> : null;
            })}
          </g>
        );
      })}
      {points.map(([x, y], i) => (
        <circle key={`d${i}`} cx={x} cy={y} r={10 * interpolate(frame, [i * 6, i * 6 + 8], [0, 1], clamp)} fill={C.accent} style={{ filter: `drop-shadow(0 0 14px ${C.accent})` }} />
      ))}
    </svg>
  );
};

// ---------------------------------------------------------------------------
// 3. Peer to peer
// ---------------------------------------------------------------------------
export const PeerToPeer: React.FC = () => (
  <AbsoluteFill style={{ scale: String(usePush()) }}>
    <Backdrop glowX={70} />
    <Mesh nodes={20} seed="p2p" opacity={0.35} />
    <Copy
      kicker="01 — Peer to peer"
      title={"Phone to phone.\nNothing in between."}
      accent={["Nothing", "in", "between"]}
      specs={["QUIC + hole punching, relay as fallback", "Every item Ed25519-signed by its author", "Relays only ever carry ciphertext"]}
    />
    <FloatingPhone src={screen("feed-dark")} x={1000} y={170} height={700} rotY={18} rotZ={-4} delay={8} glow={0.4} />
    <FloatingPhone src={screen("network-dark")} x={1290} y={110} height={820} rotY={-6} delay={14} z={2} />
    <FloatingPhone src={screen("s07-atlas")} x={1580} y={190} height={680} rotY={-20} rotZ={4} delay={20} glow={0.4} />
    <Links points={[[1150, 150], [1480, 70], [1790, 170]]} start={34} />
  </AbsoluteFill>
);

// ---------------------------------------------------------------------------
// 4. Messaging
// ---------------------------------------------------------------------------
export const Messaging: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ scale: String(usePush()) }}>
      <Backdrop glowX={30} />
      <FloatingPhone src={screen("spaces-dark")} x={150} y={150} height={780} rotY={14} delay={6} />
      <FloatingPhone src={screen("s11-chat")} x={520} y={110} height={840} rotY={-8} delay={12} z={2} />
      <Copy
        left={1040}
        width={760}
        kicker="02 — Messaging"
        title={"Messages that\nactually arrive."}
        accent={["actually", "arrive"]}
        body="Chats, groups and channels go straight to the other phone, queued until they are online."
        specs={["Durable per-recipient queue", "Signed acks + read receipts", "Group keys rotate when someone leaves"]}
      />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 5. Privacy modes
// ---------------------------------------------------------------------------
export const Privacy: React.FC = () => {
  const frame = useCurrentFrame();
  const modes = ["Standard", "Hide my IP", "Tor"];
  const active = Math.min(2, Math.floor(interpolate(frame, [30, 100], [0, 3], clamp)));
  return (
    <AbsoluteFill style={{ scale: String(usePush()) }}>
      <Backdrop glowX={72} />
      <Copy
        kicker="03 — Privacy"
        title={"You decide who\nsees your IP."}
        accent={["your", "IP"]}
        body="End-to-end encrypted in every mode. Go direct for speed, hide behind a relay, or route through Tor."
      />
      <div style={{ position: "absolute", left: 130, bottom: 150, display: "flex", gap: 20 }}>
        {modes.map((m, i) => (
          <Chip key={m} label={m} active={i === active} style={{ opacity: interpolate(frame, [20 + i * 4, 28 + i * 4], [0, 1], clamp) }} />
        ))}
      </div>
      <FloatingPhone src={screen("s09-privacy")} x={1180} y={100} height={860} rotY={-12} delay={8} zoom={interpolate(frame, [50, 120], [1, 1.22], { ...clamp, easing: Easing.inOut(Easing.cubic) })} />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 6. Mentos coin
// ---------------------------------------------------------------------------
export const Coin: React.FC = () => {
  const frame = useCurrentFrame();
  const supply = Math.round(interpolate(frame, [10, 60], [0, 100_000_000], { ...clamp, easing: Easing.out(Easing.exp) }));
  return (
    <AbsoluteFill style={{ scale: String(usePush()) }}>
      <Backdrop glowX={65} glowY={30} />
      <div style={{ position: "absolute", left: 130, top: 130 }}>
        <Kicker delay={2}>04 — Mentos coin</Kicker>
      </div>
      <div
        style={{
          position: "absolute",
          left: 130,
          top: 190,
          fontFamily: SANS,
          fontWeight: 600,
          fontSize: 124,
          letterSpacing: -6,
          color: C.ink,
          fontVariantNumeric: "tabular-nums",
          textShadow: `0 0 60px ${C.accent}33`,
        }}
      >
        {supply.toLocaleString("en-US")}
        <span style={{ fontFamily: MONO, fontSize: 40, color: C.accent, marginLeft: 16, letterSpacing: 2 }}>MNT</span>
      </div>
      <div style={{ position: "absolute", left: 130, top: 400, width: 780, display: "flex", flexDirection: "column", gap: 30 }}>
        <Headline text={"Money with\nno bank."} accent={["no", "bank"]} delay={30} size={96} />
        <Body delay={42}>One fixed supply. Every new identity gets a welcome grant from the treasury, and nobody holds its key.</Body>
        <Specs delay={52} items={["Payments signed and hash-chained", "Final by witness stake", "Escrow for every deal"]} />
      </div>
      <FloatingPhone src={screen("wallet-dark")} x={1010} y={190} height={700} rotY={16} rotZ={-3} delay={14} glow={0.5} />
      <FloatingPhone src={screen("16-ledger-dark")} x={1270} y={100} height={840} rotY={-4} delay={20} z={2} />
      <FloatingPhone src={screen("14b-tx-sheet")} x={1580} y={200} height={680} rotY={-18} rotZ={3} delay={26} glow={0.5} />
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 7. Files: hosting and transfers
// ---------------------------------------------------------------------------
const HEX = "9f3c1e7a04b2d85f6e1c03a9b7d24f8e5a1c6b0d3e9f72a48c5b1e06d3f7a92c";

export const Files: React.FC = () => {
  const frame = useCurrentFrame();
  const progress = interpolate(frame, [30, 110], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  const hash = HEX.slice(0, Math.floor(interpolate(frame, [40, 90], [0, 48], clamp)));
  return (
    <AbsoluteFill style={{ scale: String(usePush()) }}>
      <Backdrop glowX={30} />
      <FloatingPhone src={screen("s04-transfers")} x={170} y={120} height={830} rotY={12} delay={6} z={2} />
      <FloatingPhone src={screen("s08-custody")} x={560} y={200} height={700} rotY={-10} rotZ={3} delay={12} glow={0.4} />
      <Copy
        left={1060}
        width={760}
        kicker="05 — Files"
        title={"Send anything.\nHost it yourself."}
        accent={["Host", "it", "yourself"]}
        body="Files up to 512 MiB move phone to phone. Hosted files stay on your device; only people you allow keep a copy."
      >
    <div
      style={{
        width: 740,
        marginTop: 10,
        padding: "26px 30px",
        borderRadius: 26,
        backgroundColor: `${C.surface}e6`,
        border: `1.5px solid ${C.line}`,
        opacity: interpolate(frame, [24, 32], [0, 1], clamp),
        translate: `0px ${interpolate(frame, [24, 40], [30, 0], { ...clamp, easing: easeOut })}px`,
      }}
    >
      <div style={{ display: "flex", justifyContent: "space-between", fontFamily: SANS, fontSize: 30, color: C.ink }}>
        <span>trip-photos.zip</span>
        <span style={{ fontFamily: MONO, color: C.accent }}>{Math.round(progress * 100)}%</span>
      </div>
      <div style={{ marginTop: 16, height: 10, borderRadius: 5, backgroundColor: C.raised, overflow: "hidden" }}>
        <div style={{ width: `${progress * 100}%`, height: "100%", backgroundColor: C.accent, boxShadow: `0 0 20px ${C.accent}` }} />
      </div>
      <div style={{ marginTop: 16, fontFamily: MONO, fontSize: 22, color: C.muted }}>
        sha256 <span style={{ color: C.inkSoft }}>{hash}</span>
        {progress >= 1 ? <span style={{ color: C.accent }}>  ✓ verified</span> : null}
      </div>
    </div>
      </Copy>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 8. Marketplace
// ---------------------------------------------------------------------------
export const Market: React.FC = () => {
  const frame = useCurrentFrame();
  const tabs = ["Shop", "Tasks", "Exchange", "Resources", "Ads"];
  const active = Math.floor(interpolate(frame, [30, 150], [0, 5], clamp)) % 5;
  const slide = interpolate(frame, [0, 170], [80, -80], clamp);
  return (
    <AbsoluteFill style={{ scale: String(usePush()) }}>
      <Backdrop glowY={70} />
      <div style={{ position: "absolute", left: 0, right: 0, top: 90, display: "flex", flexDirection: "column", alignItems: "center", gap: 26 }}>
        <Kicker delay={2}>06 — Marketplace</Kicker>
        <Headline text="A marketplace with escrow built in." accent={["escrow"]} delay={6} size={96} style={{ textAlign: "center", justifyContent: "center" }} />
        <div style={{ display: "flex", gap: 16, marginTop: 6 }}>
          {tabs.map((t, i) => (
            <Chip key={t} label={t} active={i === active} style={{ opacity: interpolate(frame, [16 + i * 3, 24 + i * 3], [0, 1], clamp) }} />
          ))}
        </div>
      </div>
      <div style={{ position: "absolute", inset: 0, translate: `${slide}px 0px` }}>
        <FloatingPhone src={screen("06-item")} x={210} y={470} height={700} rotY={16} delay={14} glow={0.4} />
        <FloatingPhone src={screen("01-shop-dark")} x={590} y={430} height={760} rotY={6} delay={18} z={2} />
        <FloatingPhone src={screen("08-order")} x={980} y={430} height={760} rotY={-6} delay={22} z={2} />
        <FloatingPhone src={screen("02-tasks")} x={1370} y={470} height={700} rotY={-16} delay={26} glow={0.4} />
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 9. And more: a fast parallax wall of real screens with feature callouts.
// ---------------------------------------------------------------------------
const WALL = [
  ["s25-ai-chat-dark", "plugins-dark", "you-dark"],
  ["s16-midnight", "s23-ai-empty", "03-exchange"],
  ["s17-dev", "s19-profile-dark", "15-ledger"],
  ["s13-plugins", "notes-dark", "10-hub"],
  ["s12-settings-dark", "s26-ai-models", "05-ads"],
];

export const More: React.FC = () => {
  const frame = useCurrentFrame();
  const features = ["AI assistant", "Plugins", "Spaces & channels", "Voice & video calls", "Stories", "Live location"];
  const idx = Math.min(features.length - 1, Math.floor(interpolate(frame, [20, 150], [0, features.length], clamp)));
  const local = (frame - 20) % (130 / features.length);
  return (
    <AbsoluteFill>
      <Backdrop />
      <div style={{ position: "absolute", inset: 0, transform: "perspective(2400px) rotateX(18deg) rotateZ(-8deg) scale(1.25)", transformOrigin: "50% 50%" }}>
        {WALL.map((col, ci) => {
          const dir = ci % 2 === 0 ? -1 : 1;
          const y = dir * frame * 3 + (dir > 0 ? -900 : 0) - 200;
          return (
            <div key={ci} style={{ position: "absolute", left: -140 + ci * 450, top: y, display: "flex", flexDirection: "column", gap: 40 }}>
              {[...col, ...col].map((name, i) => (
                <Phone key={`${name}${i}`} src={screen(name)} height={760} glow={0} style={{ position: "relative" }} />
              ))}
            </div>
          );
        })}
      </div>
      <AbsoluteFill style={{ background: `radial-gradient(ellipse at center, ${C.bg}f2 0%, ${C.bg}cc 35%, ${C.bg}33 75%)` }} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 30 }}>
        <Kicker delay={2}>And so much more</Kicker>
        <div
          key={idx}
          style={{
            fontFamily: SANS,
            fontWeight: 600,
            fontSize: 150,
            letterSpacing: -6,
            color: C.ink,
            textShadow: `0 0 60px ${C.accent}55`,
            opacity: frame < 20 ? 0 : interpolate(local, [0, 4], [0, 1], clamp),
            filter: `blur(${interpolate(local, [0, 5], [12, 0], clamp)}px)`,
            scale: String(interpolate(local, [0, 10], [1.08, 1], { ...clamp, easing: easeOut })),
          }}
        >
          {features[idx]}
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 10. Outro
// ---------------------------------------------------------------------------
export const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame, fps, config: { damping: 16, mass: 0.7 } });
  return (
    <AbsoluteFill style={{ scale: String(usePush(1.02, 1)) }}>
      <Backdrop glowY={45} />
      <Mesh nodes={30} seed="outro" opacity={0.3} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ scale: String(0.6 + s * 0.4), opacity: s }}>
          <Mark size={170} progress={interpolate(frame, [0, 24], [0, 1], clamp)} />
        </div>
        <Headline text="Own your network." accent={["Own"]} delay={10} size={150} style={{ marginTop: 40, justifyContent: "center" }} />
        <div
          style={{
            marginTop: 40,
            fontFamily: SANS,
            fontWeight: 600,
            fontSize: 64,
            letterSpacing: -1,
            color: C.ink,
            opacity: interpolate(frame, [30, 42], [0, 1], clamp),
          }}
        >
          Mentos
        </div>
        <div
          style={{
            marginTop: 18,
            fontFamily: MONO,
            fontSize: 26,
            letterSpacing: 8,
            color: C.accent,
            opacity: interpolate(frame, [40, 52], [0, 1], clamp),
          }}
        >
          PEER-TO-PEER · NO SERVERS · YOURS
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ backgroundColor: "#000", opacity: interpolate(frame, [115, 135], [0, 1], clamp) }} />
    </AbsoluteFill>
  );
};
