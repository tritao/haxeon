import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import { repositoryLinks, sidebar } from './docs.mjs';

export default defineConfig({
  trailingSlash: 'always',
  markdown: { processor: unified({ remarkPlugins: [repositoryLinks] }) },
  integrations: [
    starlight({
      title: 'Haxeon',
      description: 'A language and runtime for cross-platform apps and tools.',
      favicon: '/favicon.svg',
      customCss: ['./src/styles/theme.css'],
      sidebar,
      components: {
        Head: './src/components/DocsHead.astro',
        Header: './src/components/DocsHeader.astro',
      },
    }),
  ],
});
