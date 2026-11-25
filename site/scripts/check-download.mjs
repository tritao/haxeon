// The download page's platform detection (src/pages/download.astro): for each kind of visitor, the matching archive is
// labelled and listed first, and a system without an archive matches none. Without JavaScript the page is unchanged.
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { launchChrome, origin, serveDirectory } from './browser.mjs';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const chrome = (os) => `Mozilla/5.0 (${os}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36`;
// [visitor, user agent, client hints or null, the archive's os-arch expected first, or null for none]
const visitors = [
  ['Windows x64', chrome('Windows NT 10.0; Win64; x64'), null, 'windows-x86_64'],
  ['Linux x86-64', chrome('X11; Linux x86_64'), null, 'linux-x86_64'],
  ['Linux arm64', chrome('X11; Linux aarch64'), null, null],
  ['Intel-reporting Mac', chrome('Macintosh; Intel Mac OS X 10_15_7'), null, 'macos-arm64'],
  ['Android phone', chrome('Linux; Android 15; Pixel 9'), null, null],
  ['iPad', chrome('Macintosh; Intel Mac OS X 10_15_7'), { touch: 5 }, null],
  ['Linux arm64 by client hints', chrome('X11; Linux x86_64'), { platform: 'Linux', architecture: 'arm', bitness: '64' }, null],
  ['Windows by client hints', chrome('Windows NT 10.0; Win64; x64'), { platform: 'Windows', architecture: 'x86', bitness: '64' }, 'windows-x86_64'],
];

const browser = await launchChrome();
try {
  for (const [visitor, userAgent, hints, expected] of visitors) {
    const context = await browser.newContext({ userAgent });
    await serveDirectory(context, dist);
    const page = await context.newPage();
    await page.addInitScript((hints) => {
      const data = hints?.platform
        ? { platform: hints.platform, getHighEntropyValues: async () => ({ architecture: hints.architecture, bitness: hints.bitness }) }
        : undefined;
      Object.defineProperty(navigator, 'userAgentData', { get: () => data });
      if (hints?.touch) Object.defineProperty(navigator, 'maxTouchPoints', { get: () => hints.touch });
    }, hints);
    assert.equal((await page.goto(origin + '/download/')).status(), 200);
    const first = page.locator('.archives > li').first();
    if (expected) {
      await page.locator('.archives > li[data-yours]').waitFor();
      assert.equal(`${await first.getAttribute('data-os')}-${await first.getAttribute('data-arch')}`, expected, `${visitor}: first archive`);
      assert.ok(await first.locator('.yours').isVisible(), `${visitor}: the archive says it is theirs`);
    } else {
      await page.waitForLoadState('networkidle');
      assert.equal(await page.locator('.archives > li[data-yours]').count(), 0, `${visitor}: no archive is theirs`);
    }
    await context.close();
  }
  const context = await browser.newContext({ javaScriptEnabled: false });
  await serveDirectory(context, dist);
  const page = await context.newPage();
  await page.goto(origin + '/download/');
  assert.equal(await page.locator('.archives > li').count(), 3, 'every archive is listed without JavaScript');
  assert.equal(await page.locator('.yours:visible').count(), 0, 'no archive is marked without JavaScript');
  await context.close();
} finally {
  await browser.close();
}
console.log(`Download page detection: ${visitors.length} kinds of visitor, and the page without JavaScript.`);
