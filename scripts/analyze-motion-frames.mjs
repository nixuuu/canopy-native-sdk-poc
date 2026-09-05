// Actual CAMetalDrawable presentation cadence, not CLI time or GPU submissions.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const quantile = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * q) - 1)];
export function analyzeMotionTrace(text, refreshHz = 60, mode = 'presented') {
  if (!['presented', 'gpu'].includes(mode)) throw new Error('Mode must be presented or gpu');
  if (!Number.isFinite(refreshHz) || refreshHz <= 0) throw new Error('Refresh rate must be positive');
  const markers = [...text.matchAll(/motion-profile (begin|end) frame=(\d+)(?: rebuilds=(\d+))?/g)];
  const samples = mode === 'presented' ? /glass-present frame=(\d+) presented_ns=(\d+)/g : /gpu-complete frame=(\d+) completed_ns=(\d+)/g;
  const presents = [...text.matchAll(samples)].map(m => ({ frame: Number(m[1]), time: Number(m[2]) }));
  const occluded = [...text.matchAll(/path=occluded frame=(\d+)/g)].map(m => Number(m[1]));
  const segments = [];
  const intervals = [];
  let begin = null;
  for (const marker of markers) {
    if (marker[1] === 'begin') { begin = Number(marker[2]); continue; }
    if (begin === null) continue;
    const end = Number(marker[2]);
    // Emitting engine frame N advances the host counter; the responding
    // drawable is N+1. Include that final drawable, even if its callback
    // arrived after the end marker on another thread.
    const inRange = frame => frame > begin && frame <= end + 1;
    const selected = presents.filter(p => inRange(p.frame));
    const timestamps = [...new Set(selected.filter(p => p.time > 0).map(p => p.time))].sort((a, b) => a - b);
    const gaps = timestamps.slice(1).map((time, i) => (time - timestamps[i]) / 1e6);
    const invalid = occluded.some(frame => frame >= begin && frame <= end + 1) ? 'occluded' : gaps.length < 2 ? 'insufficient presentations' : null;
    if (!invalid) intervals.push(...gaps);
    segments.push({ begin, end, rebuilds: marker[3] === undefined ? null : Number(marker[3]), [mode === 'presented' ? 'visibleFrames' : 'completedFrames']: timestamps.length, [mode === 'presented' ? 'discardedPresentations' : 'zeroTimestampCompletions']: selected.filter(p => p.time === 0).length, invalid });
    begin = null;
  }
  const sorted = [...intervals].sort((a, b) => a - b);
  const totalMs = intervals.reduce((a, b) => a + b, 0);
  return {
    measurement: mode === 'presented' ? 'display-presentations' : 'gpu-completions',
    refreshHz,
    validSegments: segments.filter(s => !s.invalid).length,
    rejectedSegments: segments.filter(s => s.invalid).length,
    segments,
    cadence: sorted.length ? {
      intervals: sorted.length,
      fps: intervals.length * 1000 / totalMs,
      p50Ms: quantile(sorted, .5), p90Ms: quantile(sorted, .9), p95Ms: quantile(sorted, .95), maxMs: sorted.at(-1),
      lateIntervals: sorted.filter(ms => ms > 1.5 * 1000 / refreshHz).length,
    } : null,
  };
}

if (typeof process !== 'undefined' && process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error('Usage: node scripts/analyze-motion-frames.mjs frames.log [display-hz] [presented|gpu]');
  const result = analyzeMotionTrace(readFileSync(process.argv[2], 'utf8'), Number(process.argv[3] ?? 60), process.argv[4] ?? 'presented');
  console.log(JSON.stringify(result, null, 2));
  if (!result.cadence) process.exitCode = 1;
}
