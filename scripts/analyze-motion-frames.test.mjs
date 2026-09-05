import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeMotionTrace } from './analyze-motion-frames.mjs';

const trace = `motion-profile begin frame=10 rebuilds=0
native-sdk: glass-present frame=11 presented_ns=1000000000
native-sdk: glass-present frame=13 presented_ns=1006944444
native-sdk: glass-present frame=15 presented_ns=1013888888
motion-profile end frame=16 rebuilds=0
native-sdk: glass-present frame=17 presented_ns=1020833332
`;
test('includes the final asynchronous drawable and measures uniform 144 Hz', () => {
  const report = analyzeMotionTrace(trace, 144);
  assert.equal(report.validSegments, 1);
  assert.equal(report.segments[0].visibleFrames, 4);
  assert.equal(report.segments[0].rebuilds, 0);
  assert.ok(Math.abs(report.cadence.fps - 144) < .001);
  assert.equal(report.cadence.lateIntervals, 0);
});
test('rejects occluded intervals instead of reporting a misleading frame rate', () => {
  const report = analyzeMotionTrace(trace + 'native-sdk: gpu frame-trace path=occluded frame=12\n', 144);
  assert.equal(report.rejectedSegments, 1);
  assert.equal(report.cadence, null);
});
test('keeps long gaps and does not count zero-time submissions as visible frames', () => {
  const report = analyzeMotionTrace(trace.replace('1020833332', '1027777776') + 'native-sdk: glass-present frame=14 presented_ns=0\n', 144);
  assert.equal(report.segments[0].discardedPresentations, 1);
  assert.equal(report.cadence.lateIntervals, 1);
  assert.ok(report.cadence.fps < 110);
});
test('never combines separate animations across idle gaps', () => {
  const report = analyzeMotionTrace(trace + trace.replaceAll(/frame=(\d+)/g, (_, f) => `frame=${Number(f) + 20}`).replaceAll(/presented_ns=(\d+)/g, (_, t) => `presented_ns=${Number(t) + 60e9}`), 144);
  assert.equal(report.validSegments, 2);
  assert.equal(report.cadence.intervals, 6);
  assert.ok(Math.abs(report.cadence.fps - 144) < .001);
});

test('GPU throughput is explicitly labeled and never silently replaces visible FPS', () => {
  const gpu = trace.replaceAll('glass-present', 'gpu-complete').replaceAll('presented_ns', 'completed_ns');
  assert.equal(analyzeMotionTrace(gpu, 144).cadence, null);
  const report = analyzeMotionTrace(gpu, 144, 'gpu');
  assert.equal(report.measurement, 'gpu-completions');
  assert.equal(report.segments[0].completedFrames, 4);
  assert.equal(report.segments[0].visibleFrames, undefined);
  assert.ok(Math.abs(report.cadence.fps - 144) < .001);
});
