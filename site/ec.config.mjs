import { defineEcConfig, ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
import haxe from '../extensions/vscode/syntaxes/haxe.tmLanguage.json' with { type: 'json' };
import hxi from '../extensions/vscode/syntaxes/hxi.tmLanguage.json' with { type: 'json' };
import sokolShdc from './src/syntaxes/sokol-shdc.tmLanguage.json' with { type: 'json' };
import { bundledLanguages } from 'shiki/langs';
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
// sokol-shdc embeds GLSL, which Shiki loads only when the embedding grammar brings it along.
const { default: glsl } = await bundledLanguages.glsl();

const commandBlocks = new WeakSet();
const commandStrip = {
  name: 'command strip',
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

// A text fence titled "Output" is a program's output: drawn without the editor frame, under the same run strip as a
// CodeCard's output (theme.css), instead of as a file tab.
const outputBlocks = new WeakSet();
const outputBlock = {
  name: 'output block',
  hooks: {
    preprocessCode({ codeBlock }) {
      if (codeBlock.language !== 'text' || codeBlock.props.title !== 'Output') return;
      outputBlocks.add(codeBlock);
      codeBlock.props.title = undefined;
      codeBlock.props.frame = 'none';
    },
    postprocessRenderedBlockGroup({ renderedGroupContents, renderData }) {
      if (renderedGroupContents.length !== 1 || !outputBlocks.has(renderedGroupContents[0].codeBlock)) return;
      renderData.groupAst.properties.className.push('output-block');
      renderData.groupAst.children.unshift({
        type: 'element',
        tagName: 'div',
        properties: { className: ['run-bar'] },
        children: [{ type: 'text', value: 'Output' }],
      });
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
        // The code surface is dark in both site themes, so frame titles and tabs take its colours, not the theme type's.
        'editorGroupHeader.tabsBackground': colors['code-bg'],
        'tab.activeBackground': colors['code-bg'],
        'tab.activeForeground': colors['code-fg'],
        'tab.inactiveForeground': colors['code-comment'],
        'titleBar.activeBackground': colors['code-bg'],
        'titleBar.activeForeground': colors['code-comment'],
      },
      tokenColors: [
        {
          scope: ['keyword', 'storage', 'constant.language'],
          settings: { foreground: colors['code-keyword'] },
        },
        { scope: ['keyword.operator'], settings: { foreground: colors['code-fg'] } },
        { scope: ['string'], settings: { foreground: colors['code-string'] } },
        { scope: ['comment'], settings: { foreground: colors['code-comment'] } },
        {
          scope: ['keyword.control.directive.sokol-shdc'],
          settings: { foreground: colors['code-string'], fontStyle: 'bold' },
        },
      ],
    });
  }),
  plugins: [commandStrip, outputBlock],
  shiki: { langs: [haxe, hxi, ...glsl, sokolShdc] },
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
