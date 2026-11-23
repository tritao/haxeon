import { defineEcConfig, ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import haxe from '../extensions/vscode/syntaxes/haxe.tmLanguage.json' with { type: 'json' };
import hxi from '../extensions/vscode/syntaxes/hxi.tmLanguage.json' with { type: 'json' };
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
        { scope: ['keyword', 'storage', 'constant.language'], settings: { foreground: colors['code-keyword'] } },
        { scope: ['keyword.operator'], settings: { foreground: colors['code-fg'] } },
        { scope: ['string'], settings: { foreground: colors['code-string'] } },
        { scope: ['comment'], settings: { foreground: colors['code-comment'] } },
      ],
    });
  }),
  shiki: { langs: [haxe, hxi] },
  defaultProps: { wrap: true, preserveIndent: true, hangingIndent: 4 },
  styleOverrides: {
    codeFontFamily: tokens.shared.mono,
    uiFontFamily: tokens.shared.body,
    textMarkers: {
      insBackground: ({ theme }) => tokens[theme.name].live + '38',
      insBorderColor: ({ theme }) => tokens[theme.name].live,
      insDiffIndicatorColor: ({ theme }) => tokens[theme.name]['code-comment'],
      delBackground: 'transparent',
      delBorderColor: 'transparent',
      delDiffIndicatorColor: ({ theme }) => tokens[theme.name]['code-comment'],
    },
    borderRadius: tokens.shared['radius-m'],
  },
});
