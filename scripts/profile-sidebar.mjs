// CPU-stage benchmark, not an FPS meter: CLI/IPC delays are not frame time.
// Run against an automation-enabled Canopy instance with one visible terminal.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const cwd = resolve(process.argv[2] ?? process.cwd());
const steps = Number(process.argv[3] ?? 24);
if (!Number.isInteger(steps) || steps < 2 || steps > 200 || steps % 2) {
  throw new Error('Step count must be even, between 2 and 200');
}
const cli = fileURLToPath(new URL('../node_modules/.bin/native', import.meta.url));
const snapshot = () => readFileSync(join(cwd, '.zig-cache/native-sdk-automation/snapshot.txt'), 'utf8');
const initial = snapshot();
if (!/view .*ghostty-surface .*visible=true/.test(initial)) throw new Error('Open a terminal before profiling');
const divider = initial.split('\n').find(line => line.includes('name="Split divider"'));
const id = divider?.match(/main-canvas#(\d+)/)?.[1];
if (!id) throw new Error('No Canopy split divider in the current snapshot');
const window = initial.match(/window @w1 .*bounds=\(([^)]+)\)/)?.[1];
const dimensions = window?.match(/ ([\d.]+)x([\d.]+)$/)?.slice(1).map(Number);
const dividerFrame = divider.match(/bounds=\(([\d.]+),[\d.]+ ([\d.]+)x/);
if (!dimensions || !dividerFrame) throw new Error('Cannot resolve the benchmark geometry');
const initialX = Number(dividerFrame[1]);
const dividerWidth = Number(dividerFrame[2]);
const rightRoom = dimensions[0] - initialX - dividerWidth - 520;
const delta = rightRoom >= 1 ? Math.min(240, rightRoom) : -Math.min(240, initialX - 210);
if (Math.abs(delta) < 1) throw new Error('Enlarge the window to give the divider room to move');
function run(args) {
  const result = spawnSync(cli, ['automate', ...args], { cwd, encoding: 'utf8', timeout: 30000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
}
run(['profile', 'off']);
run(['profile', 'on']);
try {
  for (let i = 0; i < steps; i++) {
    // Ratios deliberately extend beyond the divider, but stay inside pane minima.
    run(['widget-drag', 'main-canvas', id, '0.5', String(0.5 + (i % 2 ? -delta : delta) / dividerWidth)]);
  }
  const result = snapshot();
  const finalWindow = result.match(/window @w1 .*bounds=\(([^)]+)\)/)?.[1];
  const finalDimensions = finalWindow?.match(/ ([\d.]+)x([\d.]+)$/)?.slice(1).map(Number);
  if (JSON.stringify(dimensions) !== JSON.stringify(finalDimensions)) throw new Error('Window resized during benchmark; discard this run');
  const profile = result.split('\n').find(line => line.startsWith('frame_profile '));
  if (!profile) throw new Error('Runtime did not publish timing samples');
  const metrics = Object.fromEntries([...profile.matchAll(/(\w+)=(\d+)/g)].map(([, key, value]) => [key, Number(value)]));
  console.log(JSON.stringify({ window, steps, metrics, note: 'Stage CPU timings in microseconds; interval includes IPC idle time and is not measured FPS.' }, null, 2));
} finally {
  run(['profile', 'off']);
}
