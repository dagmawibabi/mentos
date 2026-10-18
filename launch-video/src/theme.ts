import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

// Mentos design tokens (lib/core/theme/tokens.dart, dark palette).
export const C = {
  bg: "#050706",
  surface: "#121514",
  raised: "#1A1E1C",
  line: "#232826",
  ink: "#ECEFED",
  inkSoft: "#C9CFCC",
  muted: "#89928E",
  faint: "#545C58",
  accent: "#34D399",
  accentDeep: "#0E9F6E",
  accentSoft: "#0F2A1F",
};

export const SANS = "Geist";
export const MONO = "GeistMono";

const weights: Array<[string, string, string]> = [
  [SANS, "400", "fonts/geist-400.ttf"],
  [SANS, "500", "fonts/geist-500.ttf"],
  [SANS, "600", "fonts/geist-600.ttf"],
  [SANS, "700", "fonts/geist-700.ttf"],
  [MONO, "400", "fonts/geist-mono-400.ttf"],
  [MONO, "500", "fonts/geist-mono-500.ttf"],
];

for (const [family, weight, file] of weights) {
  loadFont({ family, weight, url: staticFile(file) });
}

export const screen = (name: string) => staticFile(`screens/${name}.png`);
