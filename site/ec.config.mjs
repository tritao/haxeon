import { defineEcConfig, ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import haxe from '../extensions/vscode/syntaxes/haxe.tmLanguage.json' with { type: 'json' };
import hxi from '../extensions/vscode/syntaxes/hxi.tmLanguage.json' with { type: 'json' };
import tokens from './src/styles/tokens.json' with { type: 'json' };

// Shell fences are commands by convention. Scripts and explicit frames keep their normal treatment.
const shellPrompts = new Map([
  ['sh', '$'],
  ['bash', '$'],
  ['shell', '$'],
  ['console', '$'],
  ['powershell', 'PS>'],
  ['ps1', 'PS>'],
  ['pwsh', 'PS>'],
]);
const commandBlocks = new WeakSet();
const commandStrip = {
  name: 'Haxeon command strip',
  hooks: {
    preprocessCode({ codeBlock, addGutterElement }) {
      const prompt = shellPrompts.get(codeBlock.language);
      if (
        !prompt ||
        codeBlock.props.title ||
        (codeBlock.props.frame && codeBlock.props.frame !== 'auto') ||
        /^#!|^\s*(?:\$ |PS>)/m.test(codeBlock.code)
      )
        return;
      commandBlocks.add(codeBlock);
      codeBlock.props.frame = 'none';
      codeBlock.props.hangingIndent = 2;
      const renderPrompt = (visible) => ({
        type: 'element',
        tagName: 'span',
        properties: { dataCommandPrompt: prompt, ariaHidden: 'true', hidden: !visible },
        children: [],
      });
      addGutterElement({
        renderLine: ({ line }) => renderPrompt(Boolean(line.text.trim())),
        renderPlaceholder: () => renderPrompt(false),
      });
    },
    postprocessRenderedBlockGroup({ renderedGroupContents, renderData }) {
      if (
        renderedGroupContents.length === 1 &&
        commandBlocks.has(renderedGroupContents[0].codeBlock)
      ) {
        renderData.groupAst.properties.className.push('command-strip');
      }
    },
  },
};

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
        {
          scope: ['keyword', 'storage', 'constant.language'],
          settings: { foreground: colors['code-keyword'] },
        },
        { scope: ['keyword.operator'], settings: { foreground: colors['code-fg'] } },
        { scope: ['string'], settings: { foreground: colors['code-string'] } },
        { scope: ['comment'], settings: { foreground: colors['code-comment'] } },
      ],
    });
  }),
  plugins: [commandStrip],
  shiki: { langs: [haxe, hxi] },
  defaultProps: { wrap: true, preserveIndent: true, hangingIndent: 4 },
  styleOverrides: {
    codeFontFamily: 'var(--sl-font-mono)',
    uiFontFamily: 'var(--sl-font)',
    codeFontSize: 'var(--sl-text-code)',
    codeLineHeight: '1.65',
    codePaddingBlock: 'var(--hx-space-4)',
    codePaddingInline: '18px',
    textMarkers: {
      insBackground: ({ theme }) => tokens[theme.name].live + '38',
      insBorderColor: ({ theme }) => tokens[theme.name].live,
      insDiffIndicatorColor: ({ theme }) => tokens[theme.name]['code-comment'],
      delBackground: 'transparent',
      delBorderColor: 'transparent',
      delDiffIndicatorColor: ({ theme }) => tokens[theme.name]['code-comment'],
    },
    borderRadius: 'var(--hx-radius-m)',
  },
});
