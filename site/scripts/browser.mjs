// Chrome and static serving for the site's browser checks.
import { join, resolve } from 'node:path';
import { chromium } from 'playwright-core';

export const origin = 'http://localhost';

/** Chrome from CHROME_BIN when set (CI installs one), else the system's Chrome channel. */
export function launchChrome() {
  return chromium.launch({
    ...(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : { channel: 'chrome' }),
    args: ['--enable-unsafe-swiftshader'],
  });
}

/**
 * Serves `directory` at `origin` to a browser context or page, straight from disk, so a check needs neither a port nor
 * the network: any other origin is refused. A path ending in `/` serves its index.html.
 */
export async function serveDirectory(target, directory) {
  await target.route('**/*', async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    const path = url.pathname.endsWith('/') ? url.pathname + 'index.html' : url.pathname;
    await route.fulfill({ path: join(directory, path) });
  });
}

/** Saves a screenshot under SCREENSHOT_DIR when it is set, for looking at what a check saw. */
export async function screenshot(page, name) {
  if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: resolve(process.env.SCREENSHOT_DIR, `${name}.png`) });
}
