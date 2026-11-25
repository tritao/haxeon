import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchChrome, origin, screenshot, serveDirectory } from './browser.mjs';

const haxeon = fileURLToPath(new URL('../../scripts/haxeon', import.meta.url));
const work = mkdtempSync(join(tmpdir(), 'site-template-web-'));
const app = join(work, 'browser-counter');
execFileSync(haxeon, ['create', 'browser-counter', '--platforms', 'web'], { cwd: work, stdio: 'inherit' });
execFileSync(haxeon, ['build', '--target', 'wasm32', '--jobs', '2'], { cwd: app, stdio: 'inherit' });

const bundle = join(app, 'build/web/wasm32');
const browser = await launchChrome();
try {
  for (const [name, viewport, mobile] of [
    ['light', { width: 800, height: 480 }, false],
    ['mobile', { width: 390, height: 740 }, true],
  ]) {
    const page = await browser.newPage({
      viewport, colorScheme: 'light', isMobile: mobile, hasTouch: mobile,
    });
    await serveDirectory(page, bundle);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(origin + '/index.html');
    const waitForCount = async count => {
      await page.waitForFunction(
        count => {
          const canvas = document.querySelector('#canvas');
          const status = document.querySelector('#status');
          if (!status.hidden && status.textContent !== 'Loading…') throw Error(status.textContent);
          return canvas.dataset.count === String(count);
        },
        count,
      );
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assert.equal(await page.locator('#canvas').getAttribute('data-count'), String(count));
    };
    await waitForCount(0);
    const canvas = page.locator('#canvas');
    assert.ok(await canvas.isVisible());
    const label = { x: 24, y: 24, width: 160, height: 24 };
    const initial = await page.screenshot({ clip: label });
    const position = { x: 55, y: 68 };
    await canvas.click({ position });
    await waitForCount(1);
    if (mobile) await canvas.tap({ position });
    else await canvas.click({ position });
    await waitForCount(2);
    if (mobile) {
      const cdp = await page.context().newCDPSession(page);
      for (const type of ['mousePressed', 'mouseReleased']) {
        await cdp.send('Input.dispatchMouseEvent', { type, ...position, button: 'left', pointerType: 'pen', clickCount: 1 });
      }
      await waitForCount(3);
    }
    const final = await page.screenshot({ clip: label });
    assert.notDeepEqual(final, initial, 'Clicks must change the rendered counter label');
    assert.deepEqual(errors, []);
    await screenshot(page, `template-counter-${name}`);
    await page.close();
  }
} finally {
  await browser.close();
  rmSync(work, { recursive: true, force: true });
}

console.log('Generated counter rendered in Chrome and counted mouse clicks at both sizes and a touch tap and pen press at mobile size.');
