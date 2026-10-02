#!/usr/bin/env node
/* ===========================================================================
 * gen_shots.mjs —— 把 demo/ 三页渲染成 PNG，存进 ../assets/
 *
 * 本机没有 GUI 可供手动截图，所以用**无头 Edge**（Windows 11 自带）渲染。
 * 直接 `msedge --headless --screenshot` 只能截「初始状态」；要截「走到第 N 层」
 * 的状态得点按钮 —— 所以这里走 CDP（Chrome DevTools Protocol）驱动：
 * 起 Edge 的调试端口 → 连 WebSocket → 执行点击 → Page.captureScreenshot。
 *
 * 用法：
 *     node demo/gen_shots.mjs
 *     EDGE=<msedge.exe 路径> node demo/gen_shots.mjs      # 自动找失败时手动指定
 *
 * ⚠️ 页面数据来自 data/vectors.js（生成物）。改动 demo 后先重跑
 *     node demo/gen_layers.mjs && node demo/gen_compare.mjs
 *     再跑本脚本，否则截到的是旧图。
 * =========================================================================== */

import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
/* 两个去处：原图（深色）进 assets/，报告版（浅色）进 report/figures/。
   同一张截图两个去处，是因为两边的命名与用途不同（见各自 README）。 */
const OUTDIRS = {
  assets:  join(ROOT, 'assets'),
  figures: join(ROOT, 'report', 'figures')
};

/* ---- 找 Edge --------------------------------------------------------- */
const EDGE_CANDIDATES = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe'
];
const EDGE = process.env.EDGE || EDGE_CANDIDATES.find(existsSync);
if (!EDGE) {
  console.error('找不到 Edge/Chrome。用 EDGE=<路径> 指定，例如：');
  console.error('  EDGE="C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" node demo/gen_shots.mjs');
  process.exit(2);
}

/* ---- 要截哪几张 ------------------------------------------------------
 * out   : 'assets' 或 'figures'（见 OUTDIRS）
 * theme : 'dark'（原图）或 'light'（报告版，黑白可读）
 * page  : 打开哪一页
 * next  : 点几次「下一步」
 * cell  : 再点第几个格子（-1 = 不点）
 * btn   : 再点哪个按钮的 id（null = 不点）
 * clip  : 可选，CSS 选择器 —— 截到「从左上角到该元素右下角」的一块
 *         （报告版用它裁掉右面板与底部空白，否则整页又瘦又长）
 * expectBad : 可选，截图前断言 #grid 里红格（.cell.bad）的个数。
 *         对拍页用它 —— 红格数**数出来**，不从图上目视（缩小后会看错）
 *
 * 命名两边不同（各自的 README 定的，别统一）：
 *   assets  = YYYY-MM-DD_<谁>_<一句话>.png     （素材时间线）
 *   figures = 英文小写 + 下划线                 （进报告的那一版）
 * -------------------------------------------------------------------- */
const DATE = '2026-10-01';
const SHOTS = [
  /* —— 原图（深色）→ assets/ —— */
  { out: 'assets',  theme: 'dark',  file: `${DATE}_C_演示页正变换第3层蝶形高亮.png`,        page: 'index.html',   next: 3, cell: 0,  btn: null },
  { out: 'assets',  theme: 'dark',  file: `${DATE}_C_演示页逆变换第4层蝶形高亮.png`,        page: 'intt.html',    next: 4, cell: 0,  btn: null },
  { out: 'assets',  theme: 'dark',  file: `${DATE}_C_演示页对拍4096系数全中.png`,            page: 'compare.html', next: 0, cell: -1, btn: null },
  { out: 'assets',  theme: 'dark',  file: `${DATE}_C_演示页对拍阴性对照抓出1个系数不符.png`, page: 'compare.html', next: 0, cell: -1, btn: 'mNeg' },

  /* —— 报告版（浅色）→ report/figures/ —— */
  /* NTT 那张不裁：每层**所有**格子都会变（每个蝶形改两个输出），
     所以「变化高亮」没有局部性 —— 有信息的是右侧「选一个数看它的蝶形」面板，
     裁掉它这图就没内容了。 */
  { out: 'figures', theme: 'light', file: 'demo_ntt_layer3.png',      page: 'index.html',   next: 3, cell: 0,  btn: null },
  { out: 'figures', theme: 'light', file: 'demo_compare_pass.png',    page: 'compare.html', next: 0, cell: -1, btn: null,  clip: 'main > div:first-child', expectBad: 0 },
  { out: 'figures', theme: 'light', file: 'demo_compare_negctrl.png', page: 'compare.html', next: 0, cell: -1, btn: 'mNeg', clip: 'main > div:first-child', expectBad: 1 }
];

const PORT = 9333 + (process.pid % 200);   // 避开固定端口被占
const PROFILE = join(tmpdir(), 'pqc-ntt-shots-' + process.pid);

/* ---- 极简 CDP 客户端 -------------------------------------------------- */
class CDP {
  constructor(ws) { this.ws = ws; this.seq = 0; this.waiting = new Map(); }
  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((ok, no) => {
      ws.addEventListener('open', ok, { once: true });
      ws.addEventListener('error', () => no(new Error('WebSocket 连不上: ' + wsUrl)), { once: true });
    });
    return new CDP(ws);
  }
  send(method, params = {}) {
    const id = ++this.seq;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((ok, no) => {
      const t = setTimeout(() => no(new Error(method + ' 超时')), 20000);
      this.waiting.set(id, (msg) => { clearTimeout(t); msg.error ? no(new Error(method + ': ' + msg.error.message)) : ok(msg.result); });
    });
  }
  close() { try { this.ws.close(); } catch {} }
}

async function attach() {
  let list;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      list = await r.json();
      if (list.length) break;
    } catch { /* 还没起来 */ }
    await new Promise((r) => setTimeout(r, 250));
  }
  if (!list || !list.length) throw new Error('Edge 调试端口没起来（' + PORT + '）');
  const page = list.find((t) => t.type === 'page');
  return CDP.connect(page.webSocketDebuggerUrl);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  for (const dir of Object.values(OUTDIRS)) if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

  const proc = spawn(EDGE, [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    '--no-first-run',
    '--no-default-browser-check',
    '--user-data-dir=' + PROFILE,
    '--remote-debugging-port=' + PORT,
    'about:blank'
  ], { stdio: 'ignore' });

  let cdp;
  try {
    cdp = await attach();
    cdp.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      const cb = cdp.waiting.get(msg.id);
      if (cb) { cdp.waiting.delete(msg.id); cb(msg); }
    });

    await cdp.send('Page.enable');
    // 视口宽度定死；captureBeyondViewport 会把整页高度一起截下来
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 1440, height: 1000, deviceScaleFactor: 2, mobile: false
    });

    for (const shot of SHOTS) {
      const url = pathToFileURL(join(HERE, shot.page)).href +
                  (shot.theme === 'light' ? '?theme=light' : '');
      await cdp.send('Page.navigate', { url });
      await sleep(900);            // 页面脚本立刻建 DOM，稍等即可

      const clicks = [];
      for (let i = 0; i < shot.next; i++) clicks.push("document.getElementById('next').click();");
      if (shot.cell >= 0) clicks.push(`document.querySelectorAll('#grid .cell')[${shot.cell}].click();`);
      if (shot.btn) clicks.push(`document.getElementById('${shot.btn}').click();`);
      if (clicks.length) {
        await cdp.send('Runtime.evaluate', { expression: clicks.join('\n') });
        await sleep(200);
      }

      const params = { format: 'png', captureBeyondViewport: true };
      if (shot.expectBad !== undefined) {
        const r = await cdp.send('Runtime.evaluate', {
          expression: `document.querySelectorAll('#grid .cell.bad').length`,
          returnByValue: true
        });
        const got = r.result.value;
        if (got !== shot.expectBad) {
          throw new Error(`${shot.file}: 红格数应为 ${shot.expectBad}，实测 ${got} —— 图名在断言的事对不上`);
        }
        console.log(`  · ${shot.file} 红格数 ${got}（断言 ${shot.expectBad}）✅`);
      }
      if (shot.clip) {
        const r = await cdp.send('Runtime.evaluate', {
          expression: `(()=>{const e=document.querySelector(${JSON.stringify(shot.clip)});` +
                      `if(!e)return "null";const b=e.getBoundingClientRect();` +
                      `return JSON.stringify({r:b.right,b:b.bottom});})()`,
          returnByValue: true
        });
        if (r.result.value === 'null') throw new Error('clip 选择器没命中：' + shot.clip);
        const box = JSON.parse(r.result.value);
        params.clip = { x: 0, y: 0, width: Math.ceil(box.r), height: Math.ceil(box.b), scale: 1 };
      }
      const { data } = await cdp.send('Page.captureScreenshot', params);
      writeFileSync(join(OUTDIRS[shot.out], shot.file), Buffer.from(data, 'base64'));
      const size = Buffer.from(data, 'base64').length;
      console.log(`✓ ${shot.out}/${shot.file}  (${(size / 1024).toFixed(0)} KB)`);
    }
  } finally {
    if (cdp) cdp.close();
    try { spawn('taskkill', ['/pid', String(proc.pid), '/T', '/F'], { stdio: 'ignore' }); } catch {}
    await sleep(400);
    try { rmSync(PROFILE, { recursive: true, force: true }); } catch {}
  }
}

main().catch((e) => { console.error('截图失败：' + e.message); process.exit(1); });
