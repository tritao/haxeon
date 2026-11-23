import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { load } from 'cheerio';

const haxeon = fileURLToPath(new URL('../../scripts/haxeon', import.meta.url));
const $ = load(await readFile(new URL('../dist/index.html', import.meta.url), 'utf8'));
const examples = $('[data-example]').toArray();
if (!examples.length) throw new Error('The homepage has no runnable examples.');

const directory = await mkdtemp(join(tmpdir(), 'haxeon-site-examples-'));
try {
  for (const example of examples) {
    const block = $(example);
    const name = block.attr('data-example');
    const source = block
      .find('pre .cl')
      .map((_, line) => $(line).text().trimEnd())
      .get()
      .join('\n');
    const output = block.find('.out').clone();
    output.find('[data-prompt]').remove();
    const expected = output.text().trim();
    const file = join(directory, `${name}.hx`);
    await writeFile(file, source + '\n');

    const actual = execFileSync(haxeon, [file], {
      cwd: directory,
      encoding: 'utf8',
      env: { ...process.env, HAXEON_SCRIPT_CACHE: join(directory, 'cache') },
    }).trim();
    if (actual !== expected) {
      throw new Error(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
    console.log(`${name}: output verified`);
  }
} finally {
  await rm(directory, { recursive: true, force: true });
}
