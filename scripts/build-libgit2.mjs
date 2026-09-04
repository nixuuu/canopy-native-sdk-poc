import { readFile, mkdir, stat, writeFile, copyFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

// Zig downloads and verifies this exact source; never use a Homebrew dylib.
const [sourceArg, outputArg] = process.argv.slice(2);
if (process.platform !== 'darwin' || !sourceArg || !outputArg) {
  throw new Error('libgit2 requires a native macOS build and source/output paths');
}
const source = resolve(sourceArg);
const output = resolve(outputArg);
const script = await readFile(new URL(import.meta.url));
const stamp = createHash('sha256').update(script).update(source).update(process.arch).digest('hex');
if (await readFile(join(output, '.stamp'), 'utf8').catch(() => '') === stamp &&
    await stat(join(output, 'lib/libgit2.a')).then(() => true, () => false)) process.exit(0);
const run = (args) => {
  const result = spawnSync('cmake', args, { stdio: 'inherit' });
  if (result.status !== 0) process.exit(result.status ?? 1);
};
const build = join(output, 'build');
run(['-S', source, '-B', build, '-DCMAKE_BUILD_TYPE=Release',
  '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0',
  `-DCMAKE_OSX_ARCHITECTURES=${process.arch === 'arm64' ? 'arm64' : 'x86_64'}`,
  '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_TESTS=OFF', '-DBUILD_CLI=OFF',
  '-DUSE_SSH=OFF', '-DUSE_HTTPS=OFF', '-DUSE_NTLMCLIENT=OFF',
  '-DREGEX_BACKEND=builtin', '-DUSE_HTTP_PARSER=builtin',
  `-DCMAKE_INSTALL_PREFIX=${output}`]);
run(['--build', build, '--parallel', '4']);
run(['--install', build]);
await mkdir(output, { recursive: true });
await copyFile(join(source, 'COPYING'), join(output, 'COPYING'));
await writeFile(join(output, '.stamp'), stamp);
