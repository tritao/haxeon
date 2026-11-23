import { defineEcConfig, ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import tokens from './src/styles/tokens.json' with { type: 'json' };

export default defineEcConfig({
  themes: ['dark', 'light'].map((name) => {
    const colors = tokens[name];
    return new ExpressiveCodeTheme({
      name,
      type: name,
      colors: {
        'editor.background': colors['code-bg'],
        'editor.foreground': colors['code-fg'],
        'editorLineNumber.foreground': colors['code-comment'],
      },
      tokenColors: [
        { scope: ['keyword', 'storage'], settings: { foreground: colors['code-keyword'] } },
        { scope: ['string'], settings: { foreground: colors['code-string'] } },
        { scope: ['comment'], settings: { foreground: colors['code-comment'] } },
      ],
    });
  }),
  shiki: { langAlias: { hxi: 'text' } },
  styleOverrides: {
    codeFontFamily: tokens.shared.mono,
    uiFontFamily: tokens.shared.body,
    borderRadius: tokens.shared['radius-m'],
  },
});
