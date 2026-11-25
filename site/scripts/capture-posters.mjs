// Captures the UI page's Showcase posters, light and dark, from the build in public/ (npm run build:showcase first): the
// Controls page, which shows the most widgets at once, with the inspector closed as the embed starts.
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { launchChrome, origin, serveDirectory } from './browser.mjs';

const publicDirectory = fileURLToPath(new URL('../public/', import.meta.url));
// The Showcase's canvas size, which the embed's 3 / 2 aspect matches.
const width = 1200;
const height = 800;

const browser = await launchChrome();
try {
  for (const theme of ['light', 'dark']) {
    // Room for the page's margin around the canvas, which it otherwise shrinks to fit.
    const page = await browser.newPage({ viewport: { width: width + 80, height: height + 100 }, deviceScaleFactor: 2 });
    await serveDirectory(page, publicDirectory);
    await page.goto(`${origin}/ui/showcase/?theme=${theme}`);
    await page.waitForFunction(() => Number(document.documentElement.dataset.nativekitFrames) > 30, null, { timeout: 60_000 });
    const canvas = page.locator('canvas').first();
    const box = await canvas.boundingBox();
    assert.ok(box && box.width === width && box.height === height, `Expected a ${width}x${height} canvas, got ${JSON.stringify(box)}`);
    // Controls, in the catalog; then the pointer rests on the page title so nothing shows hovered.
    await page.mouse.click(box.x + 55, box.y + 259);
    await page.mouse.move(box.x + 700, box.y + 100);
    await page.waitForTimeout(1000);
    const file = `ui/showcase-${theme}.webp`;
    await sharp(await canvas.screenshot()).webp({ quality: 85 }).toFile(publicDirectory + file);
    console.log(`wrote public/${file}`);
    await page.close();
  }
} finally {
  await browser.close();
}
