// Prints how much of each described package's API has doc comments: its public types and their members, and its modules'
// functions and variables, from the files build-api.sh wrote.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const directory = process.argv[2];
const rows = [];
for (const file of readdirSync(directory).filter((name) => name.endsWith('.json')).sort()) {
  const model = JSON.parse(readFileSync(join(directory, file), 'utf8'));
  const described = new Set(model.described);
  let total = 0;
  let documented = 0;
  const count = (source) => {
    total++;
    if (source.documentation) documented++;
  };
  for (const type of model.types.filter((entry) => described.has(entry.module))) {
    count(type.source);
    for (const member of type.members) count(member.source);
  }
  for (const module of model.modules.filter((entry) => described.has(entry.path)))
    for (const member of module.members) count(member.source);
  rows.push([file.replace(/\.json$/, ''), documented, total]);
}

console.log('Doc comment coverage (declarations with a doc comment / public declarations):');
for (const [name, documented, total] of rows) {
  const percent = total === 0 ? 100 : Math.round((100 * documented) / total);
  console.log(`  ${name.padEnd(20)} ${String(documented).padStart(5)} / ${String(total).padEnd(5)} ${percent}%`);
}
