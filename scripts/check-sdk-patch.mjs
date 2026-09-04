import { readFile } from 'node:fs/promises';
const json = async (path) => JSON.parse(await readFile(new URL(path, import.meta.url), 'utf8'));
const manifest = await json('../package.json');
const inventory = await json('../patches/native-sdk-maintenance.json');
if (manifest.devDependencies['@native-sdk/cli'] !== inventory.version) throw new Error('SDK patch inventory version differs from npm pin');
const patch = await readFile(new URL(`../patches/${inventory.patch}`, import.meta.url), 'utf8');
const actual = [...patch.matchAll(/^diff --git a\/node_modules\/@native-sdk\/cli\/(\S+) /gm)].map((match) => match[1]).sort();
const documented = inventory.groups.flatMap((group) => {
  if (!group.reason || !group.tests.length) throw new Error(`Missing rationale or validation for ${group.name}`);
  return group.files;
}).sort();
if (new Set(documented).size !== documented.length || JSON.stringify(actual) !== JSON.stringify(documented)) throw new Error('SDK patch files and maintenance inventory differ');
console.log(`SDK ${inventory.version}: all ${actual.length} patched files have ownership rationale and verification mapping`);
