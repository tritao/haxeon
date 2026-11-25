import tokens from './src/styles/tokens.json' with { type: 'json' };
import { defineConfig, fontProviders } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import { fileURLToPath } from 'node:url';
import { repositoryLinks, sidebar } from './docs.mjs';

export default defineConfig({
  vite: {
    // docs.mjs resolves docs and repository paths from here once page code is bundled; see the note there.
    define: { __SITE_ROOT__: JSON.stringify(fileURLToPath(new URL('./', import.meta.url))) },
    plugins: [
      {
        name: 'theme-tokens',
        enforce: 'pre',
        transform(css, id) {
          if (!id.endsWith('/src/styles/theme.css')) return;
          return css.replaceAll(/token\((\w+)\.([\w-]+)\)/g, (_, palette, name) => {
            const value = tokens[palette]?.[name];
            if (value === undefined) throw new Error(`Unknown theme token: ${palette}.${name}`);
            return value;
          });
        },
      },
    ],
  },
  trailingSlash: 'always',
  // Downloaded at build time and served from the site, with fallback fonts sized to match so text does not jump when
  // they arrive. The tokens' font stacks use these variables; src/components/Head.astro renders and preloads them.
  fonts: [
    {
      name: 'Bricolage Grotesque',
      cssVariable: '--font-display',
      weights: [400, 600, 800],
      fallbacks: ['sans-serif'],
      // Its optical size axis tightens the letterforms of large headings.
      options: { experimental: { variableAxis: { opsz: [['12', '96']] } } },
    },
    { name: 'IBM Plex Sans', cssVariable: '--font-body', weights: [400, 500, 600], fallbacks: ['sans-serif'] },
    { name: 'JetBrains Mono', cssVariable: '--font-mono', weights: [400, 600], fallbacks: ['monospace'] },
  ].map((font) => ({ ...font, provider: fontProviders.google(), subsets: ['latin'] })),
  markdown: { processor: unified({ remarkPlugins: [repositoryLinks] }) },
  integrations: [
    starlight({
      title: 'Haxeon',
      description: 'A language and runtime for cross-platform apps and tools.',
      favicon: '/favicon.svg',
      customCss: ['./src/styles/theme.css'],
      sidebar,
      components: {
        Head: './src/components/Head.astro',
        Header: './src/components/SiteHeader.astro',
        Footer: './src/components/SiteFooter.astro',
        MarkdownContent: './src/components/MarkdownContent.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
    }),
  ],
});
