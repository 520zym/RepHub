import fs from 'node:fs/promises';
import path from 'node:path';

// 将已构建的客户端打包为可直接双击打开的离线设计稿。
const root = process.cwd();
const build = path.join(root, 'dist/client');
let html = await fs.readFile(path.join(build, 'index.html'), 'utf8');
const script = html.match(/<script\b[^>]*src="([^"]+)"[^>]*><\/script>/);
const stylesheet = html.match(/<link\b[^>]*href="([^"]+\.css)"[^>]*>/);
if (!script || !stylesheet) throw new Error('未找到构建后的入口脚本或样式');
const readAsset = name => fs.readFile(path.join(build, name.replace(/^\//, '')), 'utf8');
const [js, css] = await Promise.all([readAsset(script[1]), readAsset(stylesheet[1])]);
html = html.replace(stylesheet[0], () => `<style>${css.replaceAll('</style', '<\\/style')}</style>`);
html = html.replace(script[0], () => `<script type="module">${js.replaceAll('</script', '<\\/script')}</script>`);
await fs.writeFile(path.join(root, 'rephub.html'), html);
console.log('已导出 prototype/rephub.html（包含全部脚本、样式和图标）');
