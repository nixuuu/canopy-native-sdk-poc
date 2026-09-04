import { readFile, mkdir, copyFile, cp, stat, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

// Source is the hash-verified Zig dependency, never the installed Ghostty app.
const [sourceArg, outputArg] = process.argv.slice(2);
if (process.platform !== 'darwin' || !sourceArg || !outputArg) {
  throw new Error('Full Ghostty renderer requires a native macOS build and source/output paths');
}
const source = resolve(sourceArg);
const output = resolve(outputArg);
const manifest = await readFile(join(source, 'build.zig.zon'));
const script = await readFile(new URL(import.meta.url));
const stamp = createHash('sha256').update(manifest).update(script).update(source).update(process.arch).digest('hex');
const archive = join(output, 'lib/libghostty.a');
if (await readFile(join(output, '.stamp'), 'utf8').catch(() => '') === stamp &&
    await stat(archive).then(() => true, () => false) &&
    await stat(join(output, 'share/ghostty')).then(() => true, () => false)) process.exit(0);

const run = spawnSync('zig', ['build', '-Doptimize=ReleaseFast', '-Demit-xcframework=true',
  '-Dxcframework-target=native', '-Demit-macos-app=false', '-Demit-docs=false',
  '-Dsimd=false', '-j2', '--prefix', output], { cwd: source, stdio: 'inherit' });
if (run.status !== 0) process.exit(run.status ?? 1);
const framework = join(source, 'macos/GhosttyKit.xcframework');
const plist = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(framework, 'Info.plist')], { encoding: 'utf8' });
if (plist.status !== 0) throw new Error('Cannot inspect GhosttyKit framework');
const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
const lib = JSON.parse(plist.stdout).AvailableLibraries.find(x => x.SupportedPlatform === 'macos' && x.SupportedArchitectures.includes(arch));
if (!lib) throw new Error(`No native macOS ${arch} library in GhosttyKit`);
await mkdir(join(output, 'lib'), { recursive: true });
await copyFile(join(framework, lib.LibraryIdentifier, lib.LibraryPath), archive);
await mkdir(join(output, 'include'), { recursive: true });
await copyFile(join(source, 'include/ghostty.h'), join(output, 'include/ghostty.h'));
await cp(join(source, 'LICENSE'), join(output, 'LICENSE'));
await writeFile(join(output, '.stamp'), stamp);
