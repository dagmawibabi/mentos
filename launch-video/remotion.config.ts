/**
 * Note: When using the Node.JS APIs, the config file
 * doesn't apply. Instead, pass options directly to the APIs.
 *
 * All configuration options: https://remotion.dev/docs/config
 */

import { Config } from "@remotion/cli/config";

Config.setRspack(true);
Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
Config.setDefaultPremountInSeconds(2);

// Use the locally installed Chrome when the headless-shell download is not
// available (set REMOTION_CHROME to override).
import { existsSync } from "node:fs";
const localChrome = process.env.REMOTION_CHROME ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
if (existsSync(localChrome)) Config.setBrowserExecutable(localChrome);
