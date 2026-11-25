import { existsSync, globSync, readFileSync } from 'node:fs';
import { posix } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { visit } from 'unist-util-visit';

// Page code is bundled away from this file, so astro.config.mjs passes the site's directory in as __SITE_ROOT__;
// code the config itself runs still finds it from this file's location.
const siteRoot =
  typeof __SITE_ROOT__ === 'string' ? pathToFileURL(__SITE_ROOT__) : new URL('./', import.meta.url);
export const docsRoot = new URL('../docs/', siteRoot);
const repositoryRoot = new URL('../', siteRoot);
const userDocs = '{guides,reference,learn,coming-from}/**/*.md';
const examples = '**/examples/**';
export const docsPatterns = [userDocs, '!' + examples];

export function docsSlug(path) {
  return path
    .replace(/\.md$/, '')
    .replace(/^guides\/\d+-/, 'guides/')
    .replaceAll('_', '-')
    .toLowerCase()
    .replace(/^([\w-]+)\/readme$/, '$1')
    .replace(/\/index$/, '');
}

export const publishedDocs = new Set(
  globSync(userDocs, {
    cwd: fileURLToPath(docsRoot),
    exclude: [examples],
  })
    .map((path) => path.split('\\').join('/'))
    .sort(),
);

// Both link helpers fail the build on a missing target, so a renamed page or directory cannot ship as a dead link.
export function docsUrl(path) {
  if (!publishedDocs.has(path)) throw new Error(`docsUrl: ${path} is not a published docs page`);
  return `/${docsSlug(path)}/`;
}

export const projectRepo = 'https://github.com/tritao/haxeon';
export const sourceRef = process.env.HAXEON_SITE_VERSION || 'main';

export function repositorySource(path) {
  if (!existsSync(new URL(path, repositoryRoot))) throw new Error(`repositorySource: ${path} does not exist in the repository`);
  return `${projectRepo}/tree/${encodeURIComponent(sourceRef)}/${path}`;
}

function linkedDocs(page, directory, prefix = directory) {
  if (!publishedDocs.has(page)) return [];
  const text = readFileSync(new URL(page, docsRoot), 'utf8');
  const linked = [...text.matchAll(/\]\(([^)#?\s]+\.md)\)/g)]
    .map(([, target]) => posix.join(directory, target))
    .filter((path) => path.startsWith(prefix) && publishedDocs.has(path));
  return [...new Set(linked)];
}

// A section's README lists its pages in reading order and serves as the first page.
function readmeOrder(directory) {
  const readme = directory + 'README.md';
  return publishedDocs.has(readme) ? [readme, ...linkedDocs(readme, directory)] : [];
}

export const cliOverview = 'reference/CLI.md';
export const cliDirectory = 'reference/cli/';
export const cliGroupPages = linkedDocs(cliOverview, 'reference/', cliDirectory);

// A group lists its pages, or a directory whose unlisted pages follow, or nested groups.
const groups = [
  ['Start here', ['guides/00-get-started.md', 'guides/01-first-app.md']],
  ['Learn the language', readmeOrder('learn/'), 'learn/'],
  ['Build guides', ['guides/README.md'], 'guides/'],
  [
    'C and C++ interop',
    ['guides/04-calling-c-and-cpp.md', 'reference/C_HEADER_FFI.md', 'reference/NATIVE_MEMORY.md'],
  ],
  [
    'Reference',
    [
      ['Overview', ['reference/README.md']],
      [
        'Language',
        [
          'reference/LANGUAGE_SUPPORT.md',
          'reference/ITERATION.md',
          'reference/STRUCTURAL_EQUALITY.md',
          'reference/SCOPED_CLEANUP.md',
          'reference/KEY_PATHS.md',
        ],
      ],
      [
        'Tools',
        [cliOverview, ...cliGroupPages, 'reference/ERRORS.md', 'reference/MANIFEST.md', 'reference/RELEASES.md', 'reference/PROFILING.md'],
      ],
      [
        'Libraries',
        [
          'reference/ASYNC.md',
          'reference/JSON_WIRE.md',
          'reference/MESSAGEPACK.md',
          'reference/RPC.md',
          'reference/WRITING_SHADERS.md',
        ],
      ],
      ['Platforms and runtime', ['reference/LIVE_PATCHING.md', 'reference/ANDROID.md', 'reference/WASM_BACKEND.md']],
      // A reference page not placed above still gets published.
      ['Other', [], 'reference/'],
    ],
  ],
  ['Coming from', readmeOrder('coming-from/'), 'coming-from/'],
];

const isNested = (pages) => Array.isArray(pages) && Array.isArray(pages[0]);
const listed = (entries) =>
  entries.flatMap(([, pages]) => (isNested(pages) ? listed(pages) : Array.isArray(pages) ? pages : []));
const explicitPages = new Set(listed(groups));

function sidebarGroups(entries) {
  return entries.flatMap(([label, pages, directory]) => {
    if (isNested(pages)) {
      const items = sidebarGroups(pages);
      // The overview page stands as the first link rather than a group of one.
      if (items[0]?.label === 'Overview') items.splice(0, 1, ...items[0].items);
      return [{ label, items }];
    }
    const prefix = typeof pages === 'string' ? pages : directory;
    const paths = [
      ...(Array.isArray(pages) ? pages : []),
      ...[...publishedDocs].filter((path) => prefix && path.startsWith(prefix) && !explicitPages.has(path)),
    ];
    return paths.length ? [{ label, items: paths.map((path) => ({ slug: docsSlug(path) })) }] : [];
  });
}

export const sidebar = sidebarGroups(groups);

export function repositoryLinks() {
  return (tree, file) => {
    if (!file.path) return;
    const currentPath = fileURLToPath(docsRoot).replaceAll('\\', '/');
    const relative = posix.relative(currentPath, file.path.replaceAll('\\', '/'));
    if (relative.startsWith('../')) return;

    // Markdown keeps its repository-relative links when read on GitHub.
    const rewrite = (node) => {
      const match = /^([^?#]+)(.*)$/.exec(node.url);
      if (!match || /^(?:\/|[a-z][a-z\d+.-]*:)/i.test(node.url)) return;
      const path = posix.join(posix.dirname(relative), decodeURIComponent(match[1]));
      if (publishedDocs.has(path)) {
        node.url = docsUrl(path) + match[2];
      } else if (existsSync(new URL(path, docsRoot))) {
        // Example projects and other files that are not pages are read on GitHub.
        node.url = repositorySource('docs/' + path) + match[2];
      }
    };

    visit(tree, ['link', 'definition'], rewrite);
  };
}
