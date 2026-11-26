// Prints how much of each described package's API has documentation, from the files build-api.sh wrote: its public
// types and their members (a member that overrides or implements another documented by its comment), and its modules'
// functions and variables, without what is internal.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { apiDeclarations, documentationCoverage } from '../api.mjs';

const directory = process.argv[2];
const entries = readdirSync(directory)
  .filter((name) => name.endsWith('.json'))
  .sort()
  .map((file) => ({ directory: file.replace(/\.json$/, ''), model: JSON.parse(readFileSync(join(directory, file), 'utf8')) }));

console.log('Doc comment coverage (documented declarations / public declarations):');
for (const { directory: name, model } of entries) {
  const { types, modules } = apiDeclarations(model);
  const { documented, total } = documentationCoverage(types, modules);
  const percent = total === 0 ? 100 : Math.round((100 * documented) / total);
  console.log(`  ${name.padEnd(20)} ${String(documented).padStart(5)} / ${String(total).padEnd(5)} ${percent}%`);
}
