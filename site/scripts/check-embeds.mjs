// Drives every live embed on the built site (LiveEmbed.astro): nothing of it loads before the visitor starts it, it
// starts and draws at desktop and mobile widths, and a failed load leaves the button ready for another try.
import assert from 'node:assert/strict';
import { globSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { load } from 'cheerio';
import { launchChrome, origin, screenshot, serveDirectory } from './browser.mjs';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const embeds = [];
for (const file of globSync('**/*.html', { cwd: dist }).sort()) {
  const $ = load(await readFile(join(dist, file), 'utf8'));
  for (const element of $('[data-live-embed]').toArray()) {
    const src = $(element).attr('data-src');
    const path = new URL(src, origin).pathname;
    embeds.push({
      page: '/' + file.replace(/index\.html$/, ''),
      src,
      // Everything the embed loads sits beside its page.
      directory: path.slice(0, path.lastIndexOf('/') + 1),
      title: $(element).attr('data-title'),
      failed: $(element).attr('data-failed'),
    });
  }
}
assert.ok(embeds.length > 0, 'Expected live embeds on the built site');

const browser = await launchChrome();
try {
  for (const embed of embeds) {
    const wrapper = (page) => page.locator(`[data-live-embed][data-src="${embed.src}"]`);
    for (const [size, width] of [['desktop', 1440], ['mobile', 390]]) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      await serveDirectory(page, dist);
      const loads = [];
      page.on('request', (request) => {
        // The page may ask whether the embed is built (a HEAD request); only fetching it counts as loading.
        if (request.method() !== 'HEAD' && new URL(request.url()).pathname.startsWith(embed.directory)) loads.push(request.url());
      });
      assert.equal((await page.goto(origin + embed.page)).status(), 200);
      const start = wrapper(page).locator('[data-start]');
      await start.waitFor();
      assert.deepEqual(loads, [], `${embed.title} loaded before it was started`);

      await start.click();
      await wrapper(page).and(page.locator('[data-running]')).waitFor({ timeout: 60_000 });
      const frame = wrapper(page).locator(`iframe[title="${embed.title}"]`);
      await frame.scrollIntoViewIfNeeded();
      const box = await frame.boundingBox();
      assert.ok(box && box.x >= 0 && box.x + box.width <= width, `${embed.title} fits the viewport`);
      assert.ok(await frame.contentFrame().locator('canvas').isVisible(), `${embed.title} draws a canvas`);
      await screenshot(page, `embed-${embed.title.toLowerCase().replaceAll(' ', '-')}-${size}`);
      await page.close();
    }

    // A failed load reports itself and leaves the button ready for another try.
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    await serveDirectory(page, dist);
    await page.route(`${origin}${embed.directory}**/*.wasm`, (route) => route.abort());
    await page.goto(origin + embed.page);
    const start = wrapper(page).locator('[data-start]');
    await start.click();
    await wrapper(page).getByText(embed.failed).waitFor({ timeout: 60_000 });
    assert.equal(await start.isEnabled(), true, `${embed.title} can be started again after a failure`);
    await page.close();
    console.log(`${embed.title} on ${embed.page}: starts and draws at both widths, and recovers from a failed load.`);
  }
} finally {
  await browser.close();
}
