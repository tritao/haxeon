import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { docsPatterns, docsRoot, docsSlug, sourceRef } from '../docs.mjs';

const cliDoc = new URL('reference/CLI.md', docsRoot);
const cliSource = new URL('../src/tools/CliHelp.hx', docsRoot);
const checkoutHaxe = new URL(
  process.platform === 'win32' ? '../.tools/haxe/haxe.exe' : '../.tools/haxe/haxe',
  docsRoot,
);
const cliPrinter = fileURLToPath(new URL('../scripts/PrintCliHelp.hx', import.meta.url));

const files = glob({
  base: docsRoot,
  pattern: docsPatterns,
  generateId: ({ entry }) => docsSlug(entry),
});

const docs = defineCollection({
  schema: docsSchema(),
  loader: {
    name: 'haxeon-docs',
    async load(context) {
      const entryTypes = new Map(context.entryTypes);
      const markdown = entryTypes.get('.md');
      if (!markdown) throw new Error('The Astro Markdown content entry type is missing.');

      const haxe = process.env.HAXE ?? (existsSync(checkoutHaxe) ? fileURLToPath(checkoutHaxe) : 'haxe');
      const printHelp = () =>
        execFileSync(
          haxe,
          [
            '-cp',
            fileURLToPath(new URL('../src/', docsRoot)),
            '-cp',
            dirname(cliPrinter),
            '--run',
            'PrintCliHelp',
          ],
          { encoding: 'utf8' },
        );
      let cliHelp = printHelp();
      let cliMarkdown = readFileSync(cliDoc, 'utf8');
      const cliInputs = [fileURLToPath(cliSource), cliPrinter];

      context.watcher?.add(cliInputs);
      context.watcher?.on('change', (path) => {
        if (!cliInputs.includes(path)) return;
        try {
          cliHelp = printHelp();
          context.watcher?.emit('change', fileURLToPath(cliDoc));
        } catch (error) {
          context.logger.error(String(error));
        }
      });

      entryTypes.set('.md', {
        ...markdown,
        async getEntryInfo(input) {
          const { body, data, ...entry } = await markdown.getEntryInfo(input);
          const isCliDoc = input.fileUrl.href === cliDoc.href;
          if (isCliDoc) cliMarkdown = input.contents;
          // GitHub renders these documents without frontmatter. Use the opening heading as the page title.
          const heading = /^# ([^\r\n]+)(?:[\r\n]+|$)/.exec(body);
          const content = heading ? body.slice(heading[0].length) : body;
          return {
            ...entry,
            data: { title: heading?.[1], ...data },
            body: isCliDoc ? `${content}\n\n${cliHelp}` : content,
          };
        },
      });

      await files.load({
        ...context,
        entryTypes,
        // Example links depend on the source revision, and the CLI page includes generated help.
        generateDigest: (source) =>
          context.generateDigest(`${sourceRef}\n${source}${source === cliMarkdown ? cliHelp : ''}`),
      });
    },
  },
});

export const collections = { docs };
