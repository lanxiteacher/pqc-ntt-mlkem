// report/figures/gen_figures.mjs
//
// 从 metrics/data/metrics.csv 生成报告用的 SVG 图。
// 数字不手抄 —— CSV 由 metrics/gen_metrics.mjs 从 Vivado 报告解析生成。
//
// 用法：node report/figures/gen_figures.mjs
// 输出：report/figures/folding_sweep.svg

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const csvPath = path.resolve(here, '../../metrics/data/metrics.csv');

// ---------- 读 CSV ----------

const rows = fs
  .readFileSync(csvPath, 'utf8')
  .replace(/^﻿/, '')
  .split('\n')
  .map((l) => l.trim())
  .filter(Boolean)
  .slice(1) // 去表头
  .map((l) => l.split(','));

function series(metric) {
  const out = {};
  for (const r of rows) {
    if (r[0] === metric) out[r[2]] = Number(r[3]);
  }
  return out;
}

const PCS = ['pe1', 'pe4', 'pe16'];
const PE_LABEL = { pe1: '1', pe4: '4', pe16: '16' };

const cycles = series('NTT 周期数');
const lut = series('LUT');
const fmax = series('推算 Fmax');

const panels = [
  { title: 'NTT 周期数', unit: 'cycles', data: cycles },
  { title: 'LUT 占用', unit: '个', data: lut },
  { title: '推算 Fmax', unit: 'MHz', data: fmax },
];

// 标题里的倍数也从 CSV 算，不写死 —— 重测后重跑即可
const HEADLINE =
  `折叠度三档：周期数降 ${(cycles.pe1 / cycles.pe16).toFixed(1)}×，` +
  `LUT 升 ${(lut.pe16 / lut.pe1).toFixed(1)}×，` +
  `频率只降 ${Math.round((1 - fmax.pe16 / fmax.pe1) * 100)}%`;

for (const p of panels) {
  const missing = PCS.filter((k) => !Number.isFinite(p.data[k]));
  if (missing.length) {
    console.error(`缺数据：${p.title} 的 ${missing.join(', ')} —— 先跑 node metrics/gen_metrics.mjs`);
    process.exit(1);
  }
}

// ---------- 画 SVG ----------

const W = 960;
const H = 380;
const PAD = { l: 28, r: 28, t: 84, b: 96 };
const GAP = 36;

const panelW = (W - PAD.l - PAD.r - GAP * 2) / 3;
const panelH = H - PAD.t - PAD.b;

const INK = '#1f2933';
const MUTED = '#6b7785';
const BAR = ['#7fb3d5', '#4a90c4', '#1f6fb2'];
const AXIS = '#c3cbd4';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const fmt = (n) => (Number.isInteger(n) ? n.toLocaleString('en-US') : String(n));

let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="'Microsoft YaHei','PingFang SC',sans-serif">`;
svg += `<rect width="${W}" height="${H}" fill="#ffffff"/>`;

// 顶部标题
svg += `<text x="${W / 2}" y="34" text-anchor="middle" font-size="19" font-weight="700" fill="${INK}">${esc(HEADLINE)}</text>`;
svg += `<text x="${W / 2}" y="58" text-anchor="middle" font-size="12.5" fill="${MUTED}">横轴 = PE_NUMBER（一次算几个蝶形）｜同一份参数化 RTL、同一器件 xc7z020clg400-2、同一 Vivado 流程</text>`;

panels.forEach((p, pi) => {
  const x0 = PAD.l + pi * (panelW + GAP);
  const maxV = Math.max(...PCS.map((k) => p.data[k]));
  const top = PAD.t;
  const base = PAD.t + panelH;

  // 面板标题
  svg += `<text x="${x0 + panelW / 2}" y="${top - 24}" text-anchor="middle" font-size="14" font-weight="600" fill="${INK}">${esc(p.title)}</text>`;
  svg += `<text x="${x0 + panelW / 2}" y="${top - 9}" text-anchor="middle" font-size="11" fill="${MUTED}">${esc(p.unit)}</text>`;

  // 基线
  svg += `<line x1="${x0}" y1="${base}" x2="${x0 + panelW}" y2="${base}" stroke="${AXIS}" stroke-width="1"/>`;

  const slot = panelW / PCS.length;
  const barW = slot * 0.5;

  PCS.forEach((k, ki) => {
    const v = p.data[k];
    const h = (v / maxV) * (panelH - 30);
    const cx = x0 + slot * (ki + 0.5);
    const y = base - h;

    svg += `<rect x="${(cx - barW / 2).toFixed(1)}" y="${y.toFixed(1)}" width="${barW.toFixed(1)}" height="${h.toFixed(1)}" fill="${BAR[ki]}" rx="2"/>`;
    svg += `<text x="${cx.toFixed(1)}" y="${(y - 7).toFixed(1)}" text-anchor="middle" font-size="12.5" font-weight="600" fill="${INK}">${fmt(v)}</text>`;
    svg += `<text x="${cx.toFixed(1)}" y="${base + 18}" text-anchor="middle" font-size="13" fill="${INK}">${PE_LABEL[k]}</text>`;
  });

  // 面板横轴线
  svg += `<line x1="${x0}" y1="${base + 28}" x2="${x0 + panelW}" y2="${base + 28}" stroke="${AXIS}" stroke-width="1"/>`;
});

// 底部：横轴总标签 + 数据出处
const yBot = PAD.t + panelH + 62;
svg += `<text x="${W / 2}" y="${yBot}" text-anchor="middle" font-size="12.5" fill="${INK}">PE_NUMBER（一次算几个蝶形）</text>`;
svg += `<text x="${W / 2}" y="${yBot + 22}" text-anchor="middle" font-size="11.5" fill="${MUTED}">数据：metrics/data/metrics.csv（由 metrics/gen_metrics.mjs 从 rtl/vivado/reports/*.rpt 解析）｜Fmax 为工具推算值，非上板实测</text>`;

svg += `</svg>\n`;

const outPath = path.join(here, 'folding_sweep.svg');
fs.writeFileSync(outPath, svg, 'utf8');
console.log(`写出 ${path.relative(process.cwd(), outPath)}（${svg.length} 字节）`);
