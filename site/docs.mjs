import { existsSync, globSync } from 'node:fs';
import { posix } from 'node:path';
import { fileURLToPath } from 'node:url';
import { visit } from 'unist-util-visit';

export const docsRoot = new URL('../docs/', import.meta.url);
const userDocs = '{guides,reference,learn,coming-from}/**/*.md';
const examples = '**/examples/**';
export const docsPatterns = [userDocs, '!' + examples];

export function docsSlug(path) {
  return path
    .replace(/\.md$/, '')
    .replace(/^guides\/\d+-/, 'guides/')
    .replaceAll('_', '-')
    .toLowerCase()
    .replace(/^guides\/readme$/, 'guides')
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

export const docsUrl = (path) => `/${docsSlug(path)}/`;
export const projectRepo = 'https://github.com/tritao/haxeon';
export const sourceRef = process.env.HAXEON_SITE_VERSION || 'main';

export function repositorySource(path) {
  return `${projectRepo}/tree/${encodeURIComponent(sourceRef)}/${path}`;
}

const groups = [
  ['Start here', ['guides/00-get-started.md', 'guides/01-first-app.md']],
  ['Learn the language', 'learn/'],
  ['Build guides', ['guides/README.md'], 'guides/'],
  [
    'Runtime and targets',
    [
      'guides/02-live-editing.md',
      'reference/LIVE_PATCHING.md',
      'reference/ANDROID.md',
      'reference/WASM_BACKEND.md',
      'reference/PROFILING.md',
    ],
  ],
  [
    'C and C++ interop',
    ['guides/04-calling-c-and-cpp.md', 'reference/C_HEADER_FFI.md', 'reference/NATIVE_MEMORY.md'],
  ],
  ['Reference', 'reference/'],
  ['Coming from', 'coming-from/'],
];

const explicitPages = new Set(groups.flatMap(([, pages]) => (Array.isArray(pages) ? pages : [])));

export const sidebar = groups.flatMap(([label, pages, directory]) => {
  if (pages === 'learn/' || pages === 'coming-from/') {
    // Starlight orders these sections by the authors' sidebar metadata.
    return [...publishedDocs].some((path) => path.startsWith(pages))
      ? [{ label, items: [{ autogenerate: { directory: '../docs/' + pages.slice(0, -1) } }] }]
      : [];
  }
  const prefix = typeof pages === 'string' ? pages : directory;
  const paths = [
    ...(Array.isArray(pages) ? pages : []),
    ...[...publishedDocs].filter((path) => prefix && path.startsWith(prefix) && !explicitPages.has(path)),
  ];
  return [{ label, items: paths.map((path) => ({ slug: docsSlug(path) })) }];
});

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
