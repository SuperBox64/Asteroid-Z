// On-screen controls test: touch auto-enable, stick drag + fire (multi-touch),
// mouse drive, and the title-screen controls-cycle button.
//   node controls.js <url> <outdir> [touch|mouse|button]
const puppeteer = require('puppeteer-core');
const url = process.argv[2];
const out = process.argv[3] || '/tmp';
const mode = process.argv[4] || 'touch';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

(async () => {
  const b = await puppeteer.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', '--window-size=1240,720', '--touch-events=enabled'],
  });
  const p = await b.newPage();
  await p.setViewport({ width: 1240, height: 720, hasTouch: mode === 'touch' });
  const errs = [];
  p.on('console', m => { if (/threw|unreachable/i.test(m.text())) errs.push(m.text().slice(0, 140)); });
  await p.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });
  await sleep(3500);

  if (mode === 'button') {
    await p.screenshot({ path: `${out}/btn-title.png` });
    await p.mouse.click(620, 601);          // the retro cycle button (logical 960,150)
    await sleep(400);
    await p.mouse.click(620, 601);
    await sleep(400);
    await p.screenshot({ path: `${out}/btn-cycled.png` });
  } else if (mode === 'touch') {
    await p.touchscreen.tap(620, 360);      // first touch auto-enables stick-right
    await sleep(800);
    await p.touchscreen.tap(211, 508);      // fire button (left) restarts from attract
    await sleep(1600);
    await p.touchscreen.touchStart(1029, 508);
    await p.touchscreen.touchMove(979, 438);
    await sleep(300);
    await p.touchscreen.tap(211, 508);
    await sleep(900);
    await p.screenshot({ path: `${out}/touch-playing.png` });
    await p.touchscreen.touchEnd();
  } else {
    await p.click('canvas');
    await p.keyboard.press('Space');
    await sleep(1000);
    await p.keyboard.press('c'); await p.keyboard.press('c');
    await sleep(400);
    await p.mouse.move(1029, 508);
    await p.mouse.down();
    await p.mouse.move(989, 448, { steps: 5 });
    await sleep(900);
    await p.screenshot({ path: `${out}/mouse-stick.png` });
    await p.mouse.up();
  }
  console.log('errors:', errs.length ? errs.join('|') : 'none');
  await b.close();
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
