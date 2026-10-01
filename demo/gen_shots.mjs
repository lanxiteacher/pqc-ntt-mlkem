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
const OUT = join(ROOT, 'assets');

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
 * page  : 打开哪一页
 * next  : 点几次「下一步」
 * cell  : 再点第几个格子（-1 = 不点）
 * btn   : 再点哪个按钮的 id（null = 不点）
 * 文件名按 assets/README.md 的口径：YYYY-MM-DD_<谁>_<一句话>.png
 * -------------------------------------------------------------------- */
const DATE = '2026-10-01';
const SHOTS = [
  { file: `${DATE}_C_演示页正变换第3层蝶形高亮.png`,        page: 'index.html',   next: 3, cell: 0,    btn: null },
  { file: `${DATE}_C_演示页逆变换第4层蝶形高亮.png`,        page: 'intt.html',    next: 4, cell: 0,    btn: null },
  { file: `${DATE}_C_演示页对拍4096系数全中.png`,            page: 'compare.html', next: 0, cell: -1,   btn: null },
  { file: `${DATE}_C_演示页对拍阴性对照抓出1个系数不符.png`, page: 'compare.html', next: 0, cell: -1,   btn: 'mNeg' }
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
  if (!existsSync(OUT)) mkdirSync(OUT, { recursive: true });

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
      const url = pathToFileURL(join(HERE, shot.page)).href;
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

      const { data } = await cdp.send('Page.captureScreenshot', {
        format: 'png', captureBeyondViewport: true
      });
      writeFileSync(join(OUT, shot.file), Buffer.from(data, 'base64'));
      const size = Buffer.from(data, 'base64').length;
      console.log(`✓ assets/${shot.file}  (${(size / 1024).toFixed(0)} KB)`);
    }
  } finally {
    if (cdp) cdp.close();
    try { spawn('taskkill', ['/pid', String(proc.pid), '/T', '/F'], { stdio: 'ignore' }); } catch {}
    await sleep(400);
    try { rmSync(PROFILE, { recursive: true, force: true }); } catch {}
  }
}

main().catch((e) => { console.error('截图失败：' + e.message); process.exit(1); });
