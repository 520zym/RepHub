import pw from '/Users/zhangyiming/.npm/_npx/a1722018f28f9df2/node_modules/playwright-core/index.js';
const { chromium } = pw;
import path from 'node:path';
import fs from 'node:fs';

const root = path.resolve('docs/design/redesign-2026-10-22/round-2');
const executablePath = '/Users/zhangyiming/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const browser = await chromium.launch({ executablePath, headless: true });
const page = await browser.newPage({ viewport: { width: 1608, height: 1100 }, deviceScaleFactor: 2 });
page.on('console', (msg) => { if (msg.type() === 'error') console.error('console:', msg.text()); });
page.on('pageerror', (err) => console.error('pageerror:', err.message));
await page.goto('file://' + path.join(root, 'src/index.html'));
await page.waitForTimeout(600);
await page.evaluate(() => document.fonts.ready);
for (const [id, filename] of [['main', '01-a2-workspace.png'], ['narrow', '02-a2-narrow.png'], ['dual', '03-a2-dual-target.png']]) {
  const loc = page.locator('#' + id);
  console.log(id, await loc.boundingBox());
  await loc.screenshot({ path: path.join(root, filename) });
  console.log(filename, fs.statSync(path.join(root, filename)).size);
}
await browser.close();
