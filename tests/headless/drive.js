const puppeteer = require('puppeteer-core');

const url = process.argv[2];
const outPrefix = process.argv[3] || 'shot';

(async () => {
  const browser = await puppeteer.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', '--window-size=1240,720', '--autoplay-policy=no-user-gesture-required'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1240, height: 720 });
  const errors = [];
  page.on('console', (m) => { if (/error|trap|unreachable|RuntimeError|threw/i.test(m.text()) && !/AudioContext/i.test(m.text())) errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push('PAGEERROR ' + e.message));

  await page.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });
  await new Promise(r => setTimeout(r, 4000));
  await page.screenshot({ path: outPrefix + '-title.png' });

  await page.click('canvas');
  await page.keyboard.press('Space');
  await new Promise(r => setTimeout(r, 3000));
  await page.screenshot({ path: outPrefix + '-started.png' });

  const dirs = ['ArrowRight', 'ArrowUp', 'ArrowLeft', 'ArrowDown', 'ArrowRight', 'ArrowRight', 'ArrowUp', 'ArrowRight'];
  for (const d of dirs) {
    await page.keyboard.down(d);
    await new Promise(r => setTimeout(r, 1400));
    await page.keyboard.up(d);
  }
  await new Promise(r => setTimeout(r, 1000));
  await page.screenshot({ path: outPrefix + '-played.png' });

  console.log('ERRORS:', errors.length ? errors.slice(0, 5).join(' | ') : 'none');
  await browser.close();
})().catch(e => { console.error('DRIVER FAILED:', e.message); process.exit(1); });
