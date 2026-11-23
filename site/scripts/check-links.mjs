import { glob, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { load } from 'cheerio';

const output = fileURLToPath(new URL('../dist/', import.meta.url));
const origin = 'https://haxeon.invalid';
const pages = new Map();

for await (const file of glob('**/*.html', { cwd: output })) {
  const html = load(await readFile(join(output, file), 'utf8'));
  const ids = new Set(
    html('[id], a[name]')
      .map((_, el) => html(el).attr('id') ?? html(el).attr('name'))
      .get(),
  );
  const links = html('[href], script[src], img[src], source[src], iframe[src], [data-showcase-src]')
    .map((_, el) => html(el).attr('href') ?? html(el).attr('src') ?? html(el).attr('data-showcase-src'))
    .get();
  pages.set(file.split('\\').join('/'), { ids, links });
}

if (!pages.has('index.html')) {
  throw new Error('Build the site before checking links.');
}

const targets = new Map();
function resolveTarget(pathname) {
  if (!targets.has(pathname)) {
    targets.set(
      pathname,
      (async () => {
        const path = pathname.slice(1);
        const index = join(path, 'index.html').split('\\').join('/');
        if (pages.has(index)) return index;
        if ((await stat(join(output, path)).catch(() => null))?.isFile()) return path;
      })(),
    );
  }
  return targets.get(pathname);
}

const broken = [];
let checked = 0;
for (const [file, { links }] of pages) {
  const url = new URL(file.replace(/(^|\/)index\.html$/, '$1'), `${origin}/`);
  for (const href of new Set(links)) {
    try {
      const target = new URL(href, url);
      if (target.origin !== origin) continue;
      const path = decodeURIComponent(target.pathname);
      const fragment = decodeURIComponent(target.hash.slice(1).split(':~:text=')[0]);
      // Same-document links on the standalone 404 page resolve to its HTML file.
      const resolved = await resolveTarget(path);
      if (!resolved || (fragment && pages.has(resolved) && !pages.get(resolved).ids.has(fragment))) {
        broken.push(`${file} → ${href}`);
      }
      checked++;
    } catch (error) {
      broken.push(`${file} → ${href} (${error.message})`);
    }
  }
}

if (broken.length) {
  console.error(broken.sort().join('\n'));
  process.exitCode = 1;
} else {
  console.log(`Checked ${checked} internal links across ${pages.size} pages.`);
}
