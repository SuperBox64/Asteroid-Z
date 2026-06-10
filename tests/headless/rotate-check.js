// Rotation-direction regression: from spawn (nose up), a short left rotate
// must tilt the nose LEFT (counter-clockwise), matching macOS SpriteKit.
//   node rotate-check.js <url> <outdir>
const puppeteer = require('puppeteer-core');
const url = process.argv[2];
const out = process.argv[3] || '/tmp';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

(async () => {
  const b = await puppeteer.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: 'new', args: ['--no-sandbox', '--disable-gpu', '--window-size=1240,720'],
  });
  const p = await b.newPage();
  await p.setViewport({ width: 1240, height: 720 });
  await p.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });
  await sleep(3000);
  await p.click('canvas');
  await p.keyboard.press('Space');
  await sleep(1500);
  await p.screenshot({ path: `${out}/rot-0-spawn.png` });
  await p.keyboard.down('ArrowLeft');
  await sleep(130);
  await p.keyboard.up('ArrowLeft');
  await sleep(200);
  await p.screenshot({ path: `${out}/rot-1-left.png` });
  console.log('compare crops around (620,360): nose must tilt LEFT of vertical');
  await b.close();
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
