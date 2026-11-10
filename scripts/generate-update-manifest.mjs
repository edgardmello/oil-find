import { writeFile, rename, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { releases } from '../site/content/releases.ts';

const [plist, archive, output] = process.argv.slice(2);
if (!plist || !archive || !output) throw new Error('Usage: generate-update-manifest.mjs <Info.plist> <zip> <output>');
const value = key => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();
const version = value('CFBundleShortVersionString');
const release = releases.find(item => item.version === version);
if (!release || !release.notes.zh.length || !release.notes.en.length || [...release.notes.zh, ...release.notes.en].some(note => !note.trim())) {
  throw new Error(`Release notes for ${version} are missing in site/content/releases.ts. Packaging stopped.`);
}
const hash = createHash('sha256');
for await (const chunk of createReadStream(archive)) hash.update(chunk);
const manifest = {
  version, build: Number(value('CFBundleVersion')),
  url: `https://find.oiloil.org/downloads/Oil-Find-${version}.zip`,
  size: (await stat(archive)).size, sha256: hash.digest('hex'),
  minimumSystemVersion: value('LSMinimumSystemVersion'), published: release.date,
  // The app manifest is English-only; the bilingual notes stay on the website.
  notes: release.notes.en,
};
const temporary = `${output}.tmp`;
try {
  await writeFile(temporary, JSON.stringify(manifest, null, 2) + '\n');
  await rename(temporary, output);
} catch (error) {
  const { rm } = await import('node:fs/promises');
  await rm(temporary, { force: true });
  throw error;
}
console.log(`Manifest: ${output}`);
