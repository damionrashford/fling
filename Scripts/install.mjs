#!/usr/bin/env node
// Installs Fling via `npx github:damionrashford/fling` (or bunx). Same flow
// as get-fling.sh: fetches carry no quarantine flag, so no Gatekeeper dance.
import { execFileSync, execSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { homedir } from "node:os";

const RAW = "https://raw.githubusercontent.com/damionrashford/fling/main";
// Overridable so the flow can be exercised without replacing a real install.
const APP = process.env.FLING_INSTALL_DEST || "/Applications/Fling.app";
const isRealInstall = !process.env.FLING_INSTALL_DEST;

const run = (cmd, args) => execFileSync(cmd, args, { stdio: ["ignore", "inherit", "inherit"] });
const get = async (path) => {
  const res = await fetch(`${RAW}/${path}`);
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
};

console.log("==> Downloading Fling");
const [bin, plist] = await Promise.all([get("bin/Fling"), get("Resources/Info.plist")]);

console.log(`==> Installing to ${APP}`);
if (isRealInstall) { try { run("killall", ["Fling"]); } catch {} }
rmSync(APP, { recursive: true, force: true });
mkdirSync(`${APP}/Contents/MacOS`, { recursive: true });
mkdirSync(`${APP}/Contents/Resources`, { recursive: true });
writeFileSync(`${APP}/Contents/MacOS/Fling`, bin);
writeFileSync(`${APP}/Contents/Info.plist`, plist);
chmodSync(`${APP}/Contents/MacOS/Fling`, 0o755);
// Local ad-hoc signature: always accepted by macOS, carries no identity.
run("codesign", ["--force", "--deep", "-s", "-", APP]);

const cattPath = `${homedir()}/.local/bin/catt`;
const uvPath = `${homedir()}/.local/bin/uv`;
const onPath = (cmd) => {
  try { execSync(`command -v ${cmd}`, { stdio: "ignore" }); return true; }
  catch { return false; }
};
if (!existsSync(cattPath) && !onPath("catt")) {
  if (!existsSync(uvPath) && !onPath("uv")) {
    console.log("==> Installing uv (Python tool manager)");
    execSync("curl -fsSL https://astral.sh/uv/install.sh -o /tmp/fling-uv-install.sh && sh /tmp/fling-uv-install.sh && rm -f /tmp/fling-uv-install.sh",
             { stdio: ["ignore", "inherit", "inherit"] });
  }
  console.log("==> Installing catt (the Cast engine)");
  run(onPath("uv") ? "uv" : uvPath, ["tool", "install", "catt"]);
}

if (isRealInstall) {
  console.log("==> Launching Fling");
  run("open", [APP]);
  console.log("\nDone — Fling is the cast icon in the menu bar.");
  console.log("First run: approve the permission prompts, then use");
  console.log("'Set Up TV Power…' and type the code the TV shows.");
} else {
  console.log("Done (test destination, not launched).");
}
