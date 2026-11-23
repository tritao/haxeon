import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const guide = await readFile(new URL('../../docs/guides/00-get-started.md', import.meta.url), 'utf8');
const fences = [
  ...guide.matchAll(/^```(sh|bash|shell|console|powershell|ps1|pwsh)[ \t]*\r?\n([\s\S]*?)\r?\n^```[ \t]*$/gm),
];
assert.ok(fences.length > 0, 'Expected shell fences in the Get started guide');

const origin = 'http://localhost';
const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const pagePath = '/guides/get-started/';
const browser = await chromium.launch({ channel: 'chrome' });
try {
  const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
  // Serve built assets directly to the browser so this check needs neither a port nor external resources.
  await context.route('**/*', async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    const path = url.pathname.endsWith('/') ? url.pathname + 'index.html' : url.pathname;
    await route.fulfill({ path: join(dist, path) });
  });
  const page = await context.newPage();

  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    assert.equal((await page.goto(origin + pagePath)).status(), 200);
    await page.evaluate(() => document.fonts.ready);
    const strips = page.locator('main .command-strip');
    assert.equal(await strips.count(), fences.length, 'Expected one strip per shell fence');

    for (const [index, [, language, source]] of fences.entries()) {
      const strip = strips.nth(index);
      const prompt = /^(powershell|ps1|pwsh)$/.test(language) ? 'PS>' : '$';
      const command = source.replaceAll('\r\n', '\n');
      const lines = command.split('\n');
      assert.equal(await strip.locator('pre').getAttribute('data-language'), language);
      assert.equal(await strip.locator('.frame.is-terminal').count(), 0);
      assert.deepEqual(await strip.locator('.ec-line > .code').allInnerTexts(), lines, command);

      const renderedLines = await strip.locator('.ec-line').all();
      for (const [lineIndex, line] of renderedLines.entries()) {
        const gutter = line.locator('.gutter > [data-command-prompt]');
        assert.equal(await gutter.count(), 1, command);
        assert.equal(await gutter.getAttribute('aria-hidden'), 'true', command);
        assert.equal(await gutter.textContent(), '', command);
        if (!lines[lineIndex].trim()) {
          assert.equal(await gutter.isVisible(), false, command);
          continue;
        }
        assert.equal(await gutter.isVisible(), true, command);
        const geometry = await gutter.evaluate((prompt) => {
          const line = prompt.closest('.ec-line');
          const pre = line.closest('pre');
          const box = pre.getBoundingClientRect();
          const style = getComputedStyle(pre);
          const walker = document.createTreeWalker(line.querySelector('.code'), NodeFilter.SHOW_TEXT);
          const range = document.createRange();
          const rows = new Map();
          for (let node; (node = walker.nextNode()); ) {
            for (let offset = 0; offset < node.length; offset++) {
              if (/\s/.test(node.textContent[offset])) continue;
              range.setStart(node, offset);
              range.setEnd(node, offset + 1);
              const rect = range.getBoundingClientRect();
              if (!rect.width) continue;
              rows.set(rect.top, Math.min(rows.get(rect.top) ?? Infinity, rect.left));
            }
          }
          const promptBox = prompt.getBoundingClientRect();
          return {
            contentLeft: box.left + pre.clientLeft + parseFloat(style.paddingLeft),
            contentRight: box.left + pre.clientLeft + pre.clientWidth - parseFloat(style.paddingRight),
            promptLeft: promptBox.left,
            promptRight: promptBox.right,
            promptText: getComputedStyle(prompt, '::before').content,
            userSelect: getComputedStyle(prompt).userSelect,
            rowStarts: [...rows.values()],
          };
        });
        const { contentLeft, contentRight, promptLeft, promptRight, rowStarts } = geometry;
        const firstGlyph = rowStarts[0];
        const message = `${width}px, ${lines[lineIndex]} (${JSON.stringify(geometry)})`;
        assert.equal(geometry.promptText, JSON.stringify(prompt), message);
        assert.equal(geometry.userSelect, 'none', message);
        assert.ok(promptLeft >= contentLeft - 0.5 && promptRight > promptLeft, message);
        assert.ok(firstGlyph >= promptRight && firstGlyph < contentRight, message);
        assert.ok(rowStarts.slice(1).every((left) => left > firstGlyph && left < contentRight), message);
        if (width === 390 && /^sudo (apt-get|dnf) /.test(lines[lineIndex])) {
          assert.ok(rowStarts.length > 1, message);
        }
      }

      await strip.hover();
      await strip.getByRole('button', { name: /copy/i }).click();
      assert.equal(await page.evaluate(() => navigator.clipboard.readText()), command);
    }
  }
  console.log(`Verified ${fences.length} Get started command strips in Chrome at desktop and mobile widths.`);
} finally {
  await browser.close();
}
