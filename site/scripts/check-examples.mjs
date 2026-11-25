import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { load } from 'cheerio';

const root = fileURLToPath(new URL('../../', import.meta.url));
const haxeon = join(root, 'scripts/haxeon');
const haxe = join(root, '.tools/haxe/haxe');
const $ = load(await readFile(new URL('../dist/index.html', import.meta.url), 'utf8'));
if (!$('[data-example]').length) throw new Error('The homepage has no runnable examples.');
// The homepage's examples, then the Language page's; the tour appears on both, so each name runs once.
const examples = [];
const seen = new Set();
for (const page of ['index.html', 'language/index.html']) {
  const document = load(await readFile(new URL('../dist/' + page, import.meta.url), 'utf8'));
  for (const element of document('[data-example]').toArray()) {
    const name = document(element).attr('data-example');
    if (!seen.has(name)) {
      seen.add(name);
      examples.push(element);
    }
  }
}

function sourceFor(block, language) {
  const lines = block.find(`pre[data-language="${language}"] .ec-line > .code`).toArray();
  if (!lines.length) throw new Error(`Missing rendered ${language} example`);
  return lines.map((line) => $(line).text().trimEnd()).join('\n') + '\n';
}

function run(args, cwd) {
  return execFileSync(haxeon, args, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, HAXEON_SCRIPT_CACHE: join(cwd, 'cache') },
  }).trim();
}

async function runGeometry(block, source, directory) {
  const project = join(directory, 'geometry');
  const files = {
    'haxeon.toml': `version = 1
entry = "Main"
sourceRoots = ["src"]

[native.cmake]
source = "native"
target = "geometry"
library = "geometry"

[ffi]
imports = ["ffi/geometry.ffi.json"]
projections = ["ffi/geometry.hxmap"]
`,
    'ffi/geometry.ffi.json': JSON.stringify({
      version: 1,
      name: 'geometry',
      language: 'c',
      header: '../native/geometry.h',
      library: 'geometry',
      interface: 'Geometry',
    }),
    'ffi/geometry.hxmap': JSON.stringify({
      interface: 'Geometry',
      functionPrefix: 'geo_',
      functionCase: 'camel',
      typeNames: { geo_point: 'Point' },
    }),
    'native/CMakeLists.txt': `cmake_minimum_required(VERSION 3.20)
project(geometry LANGUAGES C)
add_library(geometry SHARED geometry.c)
set_target_properties(geometry PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
if(UNIX)
  target_link_libraries(geometry PRIVATE m)
endif()
`,
    'native/geometry.c': `#include "geometry.h"
#include <math.h>

double geo_distance(const geo_point *a, const geo_point *b) {
  return hypot(a->x - b->x, a->y - b->y);
}

void geo_translate(geo_point *point, double dx, double dy) {
  point->x += dx;
  point->y += dy;
}
`,
    'native/geometry.h': sourceFor(block, 'c'),
    'src/Main.hx': source,
  };
  for (const folder of ['ffi', 'native', 'src']) await mkdir(join(project, folder), { recursive: true });
  for (const [name, content] of Object.entries(files)) await writeFile(join(project, name), content);

  const shown = sourceFor(block, 'hxi');
  const target = shown.match(/@target\(\s*"([^"]+)"\s*\)/)?.[1];
  if (!target) throw new Error('geometry: missing target in rendered HXI');
  run([
    'ffi', 'import', `--target=${target}`, '--library=geometry', '--interface=Geometry',
    '--output=geometry.hxi', 'native/geometry.h',
  ], project);
  const generated = execFileSync(haxe, [
    'common.hxml', '-cp', 'site/scripts', '--run', 'RenderGeometryHxi', join(project, 'geometry.hxi'),
  ], { cwd: root, encoding: 'utf8' });
  const sample = await readFile(new URL('../src/components/home/geometry.hxi', import.meta.url), 'utf8');
  if (generated !== sample || generated.replaceAll('\t', '  ') !== shown) {
    throw new Error('geometry: rendered HXI differs from the generated binding');
  }
  return run(['run', '--quiet', '--jobs', '2'], project);
}

const directory = await mkdtemp(join(tmpdir(), 'haxeon-site-examples-'));
try {
  for (const example of examples) {
    const block = $(example);
    const name = block.attr('data-example');
    const source = sourceFor(block, 'haxe');
    const output = block.find('.output-pane').clone();
    output.find('[data-prompt]').remove();
    const expected = output.text().trim();
    let actual;
    if (name === 'geometry') {
      actual = await runGeometry(block, source, directory);
    } else {
      const file = join(directory, `${name}.hx`);
      await writeFile(file, source);
      actual = run([file], directory);
    }
    if (actual !== expected) {
      throw new Error(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
    console.log(`${name}: output verified`);
  }

  const ui = load(await readFile(new URL('../dist/ui/index.html', import.meta.url), 'utf8'));
  const view = sourceFor(ui('[data-example="ui-counter"]'), 'haxe').trimEnd();
  const project = join(directory, 'my_app');
  await cp(new URL('../../docs/guides/examples/01-first-app/my_app/', import.meta.url), project, {
    recursive: true,
  });
  const host = await readFile(join(project, 'src/Main.hx'), 'utf8');
  if (!host.replaceAll('\t', '  ').includes(view.replace(/^/gm, '  '))) {
    throw new Error('ui-counter: rendered view differs from the first-app project');
  }
  run(['create', '.'], project);

  const input = join(directory, 'counter-input.json');
  await writeFile(input, JSON.stringify({
    version: 1,
    events: [
      { at: 0.3, kind: 'down', x: 50, y: 110 },
      { at: 0.4, kind: 'up', x: 50, y: 110 },
      { at: 0.5, kind: 'down', x: 50, y: 110 },
      { at: 0.6, kind: 'up', x: 50, y: 110 },
    ],
  }));
  const capture = join(directory, 'counter-capture');
  const args = ['run', '--quiet', '--jobs', '2', '--', '--capture-seconds=1',
    `--capture=${capture}`, `--input-script=${input}`];
  if (process.platform === 'linux' && !process.env.DISPLAY) {
    execFileSync('xvfb-run', ['-a', haxeon, ...args], { cwd: project, stdio: 'inherit' });
  } else {
    run(args, project);
  }
  const { count } = JSON.parse(await readFile(join(capture, 'app-state.json'), 'utf8'));
  if (count !== 2) throw new Error(`ui-counter: expected two clicks, got ${count}`);
  console.log('ui-counter: native window and clicks verified');
} finally {
  await rm(directory, { recursive: true, force: true });
}
