// Uploads one artifact per folder of a directory, named after the folder.
//
// Used by the reuse-artifacts job of ci.yml: scripts/Get-ReleaseFiles.ps1
// writes the files of every reused build unit to <directory>/<unit>, and each
// folder becomes the artifact binaries-<...> the job of the unit would have
// uploaded. actions/upload-artifact uploads one artifact per step, so it
// cannot take a list known only at run time; this is the library it uses.
//
// Runs in actions/github-script, the only place with ACTIONS_RUNTIME_TOKEN,
// after `npm install @actions/artifact` in the workspace:
//
//     const { run } = await import(`${process.env.GITHUB_WORKSPACE}/scripts/upload-reused-artifacts.mjs`)
//     await run({ directory: 'reused', core })
import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { DefaultArtifactClient } from '@actions/artifact';

export async function run({ directory, core, retentionDays = 1, concurrency = 4 }) {
  const root = path.resolve(directory);
  const entries = await readdir(root, { withFileTypes: true });
  const units = entries.filter(entry => entry.isDirectory()).map(entry => entry.name).sort();
  const client = new DefaultArtifactClient();

  let next = 0;
  const failures = [];
  async function worker() {
    while (next < units.length) {
      const name = units[next++];
      const folder = path.join(root, name);
      const files = (await readdir(folder, { withFileTypes: true, recursive: true }))
        .filter(entry => entry.isFile())
        .map(entry => path.join(entry.parentPath, entry.name));
      if (files.length === 0) {
        failures.push(`${name}: no files`);
        continue;
      }

      try {
        const { id, size } = await client.uploadArtifact(name, files, folder, { retentionDays });
        core.info(`${name}: ${files.length} files, ${size} bytes, artifact ${id}`);
      } catch (error) {
        failures.push(`${name}: ${error.message}`);
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(concurrency, units.length) }, worker));
  if (failures.length > 0) {
    throw new Error(`Cannot upload ${failures.length} artifacts:\n${failures.join('\n')}`);
  }

  core.info(`Uploaded ${units.length} artifacts`);
}
