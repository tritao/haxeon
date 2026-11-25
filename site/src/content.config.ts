import { execFile } from 'node:child_process';
import { existsSync, globSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { cliDirectory, cliGroupPages, cliOverview, docsPatterns, docsRoot, docsSlug, sourceRef } from '../docs.mjs';

const cliSource = new URL('../src/tools/CliHelp.hx', docsRoot);
const checkoutHaxe = new URL(
  process.platform === 'win32' ? '../.tools/haxe/haxe.exe' : '../.tools/haxe/haxe',
  docsRoot,
);
const cliPrinter = fileURLToPath(new URL('../scripts/PrintCliHelp.hx', import.meta.url));
const exec = promisify(execFile);
// Rendered pages depend on docs.mjs too: it decides slugs and rewrites links.
const docsConfig = readFileSync(new URL('../docs.mjs', import.meta.url), 'utf8');

type CliHelp = {
  overview: string;
  groups: { title: string; commands: { name: string; help: string }[] }[];
};

const textBlock = (help: string) => '```text\n' + help + '\n```';

function cliPages(help: CliHelp) {
  const groupPaths = help.groups.map(({ title }) =>
    cliDirectory + title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') + '.md',
  );
  const actualPaths = new Set(globSync(cliDirectory + '**/*.md', { cwd: fileURLToPath(docsRoot) })
    .map((path) => path.split('\\').join('/')));
  for (const path of groupPaths) {
    if (!actualPaths.delete(path)) throw new Error(`Missing or duplicate CLI group page: ${path}`);
  }
  if (actualPaths.size) throw new Error(`CLI pages without a help group: ${[...actualPaths].join(', ')}`);
  if (groupPaths.length !== cliGroupPages.length || groupPaths.some((path, i) => path !== cliGroupPages[i])) {
    throw new Error(`List the CLI group pages in ${cliOverview} in CliHelp order: ${groupPaths.join(', ')}`);
  }

  const pages = new Map<string, (content: string) => string>();
  pages.set(new URL(cliOverview, docsRoot).href, (content) =>
    `${content.trimEnd()}\n\n## Command help\n\n${textBlock(help.overview)}\n`,
  );
  for (const [index, group] of help.groups.entries()) {
    const path = groupPaths[index];
    pages.set(new URL(path, docsRoot).href, (content) => {
      const commands = new Map(group.commands.map(({ name, help }) => [name, help]));
      const body = content.replace(/^## (.+)\r?$/gm, (heading, name: string) => {
        const help = commands.get(name);
        if (help === undefined) throw new Error(`Unexpected CLI command heading in ${path}: ${name}`);
        commands.delete(name);
        return `${heading}\n\n${textBlock(help)}`;
      });
      if (commands.size) throw new Error(`Missing CLI command headings in ${path}: ${[...commands.keys()].join(', ')}`);
      return body;
    });
  }
  return pages;
}

const files = glob({
  base: docsRoot,
  pattern: docsPatterns,
  generateId: ({ entry }) => docsSlug(entry),
});

const docs = defineCollection({
  schema: docsSchema(),
  loader: {
    name: 'repository-docs',
    async load(context) {
      const entryTypes = new Map(context.entryTypes);
      const markdown = entryTypes.get('.md');
      if (!markdown) throw new Error('The Astro Markdown content entry type is missing.');

      const haxe = process.env.HAXE ?? (existsSync(checkoutHaxe) ? fileURLToPath(checkoutHaxe) : 'haxe');
      const printHelp = async () => {
        const { stdout } = await exec(
          haxe,
          [
            'common.hxml',
            '-cp',
            dirname(cliPrinter),
            '--run',
            'PrintCliHelp',
          ],
          { cwd: fileURLToPath(new URL('../', docsRoot)), encoding: 'utf8' },
        );
        return stdout;
      };
      let cliHelp = await printHelp();
      let generatedPages = cliPages(JSON.parse(cliHelp));
      const cliInputs = [fileURLToPath(cliSource), cliPrinter];
      let latestRefresh = 0;

      context.watcher?.add(cliInputs);
      context.watcher?.on('change', async (path) => {
        if (!cliInputs.includes(path)) return;
        const refresh = ++latestRefresh;
        try {
          const nextHelp = await printHelp();
          if (refresh !== latestRefresh) return;
          generatedPages = cliPages(JSON.parse(nextHelp));
          cliHelp = nextHelp;
          for (const page of generatedPages.keys()) {
            context.watcher?.emit('change', fileURLToPath(page));
          }
        } catch (error) {
          context.logger.error(String(error));
        }
      });

      entryTypes.set('.md', {
        ...markdown,
        async getEntryInfo(input) {
          const { body, data, ...entry } = await markdown.getEntryInfo(input);
          // GitHub renders these documents without frontmatter. Use the opening heading as the page title.
          const heading = /^# ([^\r\n]+)(?:[\r\n]+|$)/.exec(body);
          const content = heading ? body.slice(heading[0].length) : body;
          return {
            ...entry,
            data: { title: heading?.[1], ...data },
            body: generatedPages.get(input.fileUrl.href)?.(content) ?? content,
          };
        },
      });

      await files.load({
        ...context,
        entryTypes,
        // Repository links depend on the source revision. Generated help and docs.mjs can change without Markdown edits.
        generateDigest: (source) => context.generateDigest(`${sourceRef}\n${docsConfig}\n${cliHelp}\n${source}`),
      });
    },
  },
});

export const collections = { docs };
