import tokens from './src/styles/tokens.json' with { type: 'json' };
import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import { repositoryLinks, sidebar } from './docs.mjs';

export default defineConfig({
  vite: {
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
  markdown: { processor: unified({ remarkPlugins: [repositoryLinks] }) },
  integrations: [
    starlight({
      title: 'Haxeon',
      description: 'A language and runtime for cross-platform apps and tools.',
      favicon: '/favicon.svg',
      customCss: ['./src/styles/theme.css'],
      sidebar,
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        {
          tag: 'link',
          attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: 'anonymous' },
        },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href: 'https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,400;12..96,600;12..96,800&family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;600&display=swap',
          },
        },
      ],
      components: {
        Header: './src/components/SiteHeader.astro',
        Footer: './src/components/SiteFooter.astro',
        MarkdownContent: './src/components/MarkdownContent.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
    }),
  ],
});
