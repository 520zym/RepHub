import pw from '/Users/zhangyiming/.npm/_npx/a1722018f28f9df2/node_modules/playwright-core/index.js';
const { chromium } = pw;
import path from 'node:path';
import fs from 'node:fs';

const root = path.resolve('docs/design/canvas-2026-10-22');
const src = path.join(root, 'src');
const executablePath = '/Users/zhangyiming/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const browser = await chromium.launch({ executablePath, headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1100 }, deviceScaleFactor: 2 });
page.on('console', (msg) => { if (msg.type() === 'error') console.error('console:', msg.text()); });
page.on('pageerror', (err) => console.error('pageerror:', err.message));

const targets = [
  ['history.html', 'screen-history', '02-history.png'],
  ['file-history.html', 'screen-file-history', '03-file-history.png'],
  ['welcome.html', 'screen-welcome', '04-welcome.png'],
  ['open-local.html', 'screen-open-local', '05-open-local.png'],
  ['acquire-browse.html', 'screen-acquire-browse', '06-acquire-browse.png'],
  ['commit.html', 'screen-commit', '07-commit-preflight.png'],
  ['conflict.html', 'screen-conflict', '08-conflict-editor.png'],
  ['ai-review.html', 'screen-ai-review', '09-ai-review.png'],
  ['settings-ai.html', 'screen-settings-ai', '10-settings-ai.png'],
  ['settings-appearance.html', 'screen-settings-appearance', '11-settings-appearance.png'],
  ['management.html', 'screen-management', '12-management.png'],
  ['migration.html', 'screen-migration', '13-migration.png'],
  ['flow.html', 'screen-flow', '14-acquisition-flow.png'],
  ['utility.html', 'screen-utility', '15-utility-dialogs.png']
];

const wanted = process.argv.slice(2);
for (const [file, id, outName] of targets) {
  if (wanted.length && !wanted.some(w => file.includes(w) || outName.includes(w))) continue;
  const fp = path.join(src, file);
  if (!fs.existsSync(fp)) { console.log('skip', file); continue; }
  await page.goto('file://' + fp);
  await page.waitForTimeout(450);
  await page.evaluate(() => document.fonts.ready);
  const loc = page.locator('#' + id);
  if (!(await loc.count())) { console.log('missing target', id); continue; }
  const box = await loc.boundingBox();
  await loc.screenshot({ path: path.join(root, outName) });
  console.log(outName, box, fs.statSync(path.join(root, outName)).size);
}
const ov = await browser.newPage({ viewport: { width: 2450, height: 1950 }, deviceScaleFactor: 1.5 });
ov.on('pageerror', (err) => console.error('overview pageerror:', err.message));
await ov.goto('file://' + path.join(src, 'overview.html'));
await ov.waitForTimeout(900);
await ov.evaluate(() => document.fonts.ready);
const overview = ov.locator('#screen-overview');
console.log('overview', await overview.boundingBox());
await overview.screenshot({ path: path.join(root, '00-overview.png') });
console.log('00-overview.png', fs.statSync(path.join(root, '00-overview.png')).size);
await ov.close();
await browser.close();