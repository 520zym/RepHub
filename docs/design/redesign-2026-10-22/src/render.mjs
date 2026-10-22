import pw from '/Users/zhangyiming/.npm/_npx/a1722018f28f9df2/node_modules/playwright-core/index.js';
const { chromium } = pw;
import path from 'node:path';
import fs from 'node:fs';

const root = path.resolve('docs/design/redesign-2026-10-22');
const out = root;
const executablePath = '/Users/zhangyiming/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const browser = await chromium.launch({ executablePath, headless: true });
const page = await browser.newPage({ viewport: { width: 1608, height: 1100 }, deviceScaleFactor: 2 });
page.on('console', (msg) => { if (msg.type() === 'error') console.error('console:', msg.text()); });
page.on('pageerror', (err) => console.error('pageerror:', err.message));
await page.goto('file://' + path.join(root, 'src/index.html'));
await page.waitForTimeout(600);
await page.evaluate(() => document.fonts.ready);
for (const [id, filename] of [['atelier', '01-atelier.png'], ['nightshift', '02-nightshift.png'], ['canvas', '03-canvas.png']]) {
  const loc = page.locator('#' + id);
  const box = await loc.boundingBox();
  console.log(id, box);
  await loc.screenshot({ path: path.join(out, filename) });
  const stat = fs.statSync(path.join(out, filename));
  console.log(filename, stat.size);
}
const overview = await browser.newPage({ viewport: { width: 2400, height: 1400 }, deviceScaleFactor: 1.5 });
overview.on('pageerror', (err) => console.error('overview pageerror:', err.message));
await overview.goto('file://' + path.join(root, 'src/overview.html'));
await overview.waitForTimeout(700);
await overview.evaluate(() => document.fonts.ready);
const poster = overview.locator('.poster');
console.log('overview', await poster.boundingBox());
await poster.screenshot({ path: path.join(out, '00-overview.png') });
console.log('00-overview.png', fs.statSync(path.join(out, '00-overview.png')).size);
await overview.close();
await browser.close();
