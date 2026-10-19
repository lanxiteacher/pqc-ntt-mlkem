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
    // 七列格式：指标名称, 类别, 数值, 单位, 测量条件, 测试次数 / 时长, 证据文件
    // 「档位」在测量条件里（例如「档位 pe1；post-route……」）
    if (r[0] !== metric) continue;
    const m = /^档位 (pe(?:1|4|16))；/.exec(r[4] || '');
    if (m) out[m[1]] = Number(r[2]);
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

/* ===========================================================================
 * 第二张图：Pareto / ATP / roofline（出彩组合 #7）
 * 数据：metrics/data/pareto.csv（由 metrics/gen_pareto.mjs 生成）
 * =========================================================================== */

const paretoPath = path.resolve(here, '../../metrics/data/pareto.csv');
if (!fs.existsSync(paretoPath)) {
  console.error('缺 metrics/data/pareto.csv —— 先跑 node metrics/gen_pareto.mjs');
  process.exit(1);
}
const prow = fs.readFileSync(paretoPath, 'utf8').split('\n')
  .map((l) => l.trim()).filter(Boolean).slice(1).map((l) => l.split(','));
const get = (name) => {
  const r = prow.find((x) => x[0] === name);
  if (!r) { console.error('pareto.csv 缺行：' + name); process.exit(1); }
  return { pe1: Number(r[1]), pe4: Number(r[2]), pe16: Number(r[3]) };
};
const P = {
  cycles: get('NTT 周期数'),
  lut: get('LUT'),
  atp: get('ATP（LUT × cycle）'),
  atpNorm: get('ATP 归一（pe1 = 1）'),
  tputCore: get('吞吐 @ 核推算 Fmax'),
  tputBoard: get('吞吐 @ 板上提频频率'),
  bwReqMB: get('维持核吞吐所需带宽'),
  link115: get('链路事务率上限 @115200'),
  link921: get('链路事务率上限 @921600'),
  powerBoost: get('功耗 @ 提频（估算）')
};

const PW = 1200, PH = 500, PP = { l: 54, r: 30, t: 112, b: 92 };
const PGAP = 42;
const panelW2 = (PW - PP.l - PP.r - PGAP * 2) / 3;
const panelH2 = PH - PP.t - PP.b;
const TOP = PP.t, BASE = PP.t + panelH2;

const INK2 = '#1f2933', MUTED2 = '#6b7785', AXIS2 = '#c3cbd4', GRID2 = '#e8edf2';
const COL = { pe1: '#7fb3d5', pe4: '#4a90c4', pe16: '#1f6fb2' };
const KEY = ['pe1', 'pe4', 'pe16'];
const LBL = { pe1: 'pe1 · 1 蝶形', pe4: 'pe4 · 4 蝶形', pe16: 'pe16 · 16 蝶形' };

const esc2 = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const fmt2 = (n, d = 0) => Number(n).toLocaleString('en-US', {
  minimumFractionDigits: d, maximumFractionDigits: d
});

let s2 = `<svg xmlns="http://www.w3.org/2000/svg" width="${PW}" height="${PH}" viewBox="0 0 ${PW} ${PH}" font-family="'Microsoft YaHei','PingFang SC',sans-serif">`;
s2 += `<rect width="${PW}" height="${PH}" fill="#ffffff"/>`;
s2 += `<text x="${PW / 2}" y="30" text-anchor="middle" font-size="19" font-weight="700" fill="${INK2}">Pareto、ATP 与 roofline：三档折叠度的取舍</text>`;
s2 += `<text x="${PW / 2}" y="52" text-anchor="middle" font-size="12" fill="${MUTED2}">同一份参数化 RTL、同一器件 xc7z020clg400-2 ｜ 功耗为 Vivado vectorless 估算（非实测）</text>`;

const px = (pi) => PP.l + pi * (panelW2 + PGAP);
const title2 = (pi, t, sub) => {
  const x0 = px(pi);
  s2 += `<text x="${x0 + panelW2 / 2}" y="${TOP - 36}" text-anchor="middle" font-size="14" font-weight="600" fill="${INK2}">${esc2(t)}</text>`;
  s2 += `<text x="${x0 + panelW2 / 2}" y="${TOP - 18}" text-anchor="middle" font-size="11" fill="${MUTED2}">${esc2(sub)}</text>`;
};

/* ---- 面板 1：Pareto（LUT vs 吞吐） ------------------------------------- */
{
  const pi = 0, x0 = px(pi);
  title2(pi, 'Pareto：面积 vs 吞吐', '气泡大小 = 功耗（估算）');
  const xMax = 10000, yMax = 2500000;
  const X = (v) => x0 + (v / xMax) * panelW2;
  const Y = (v) => BASE - (v / yMax) * panelH2;

  for (let i = 0; i <= 4; i++) {
    const v = (xMax / 4) * i;
    s2 += `<line x1="${X(v).toFixed(1)}" y1="${TOP}" x2="${X(v).toFixed(1)}" y2="${BASE}" stroke="${GRID2}"/>`;
    s2 += `<text x="${X(v).toFixed(1)}" y="${BASE + 16}" text-anchor="middle" font-size="10" fill="${MUTED2}">${fmt2(v)}</text>`;
  }
  for (let i = 0; i <= 5; i++) {
    const v = 500000 * i;
    s2 += `<line x1="${x0}" y1="${Y(v).toFixed(1)}" x2="${x0 + panelW2}" y2="${Y(v).toFixed(1)}" stroke="${GRID2}"/>`;
    s2 += `<text x="${x0 - 6}" y="${(Y(v) + 4).toFixed(1)}" text-anchor="end" font-size="10" fill="${MUTED2}">${v === 0 ? '0' : (v / 1e6).toFixed(1) + 'M'}</text>`;
  }
  s2 += `<line x1="${x0}" y1="${BASE}" x2="${x0 + panelW2}" y2="${BASE}" stroke="${AXIS2}"/>`;
  s2 += `<line x1="${x0}" y1="${TOP}" x2="${x0}" y2="${BASE}" stroke="${AXIS2}"/>`;
  s2 += `<text x="${x0 + panelW2 / 2}" y="${BASE + 36}" text-anchor="middle" font-size="11.5" fill="${INK2}">LUT（post-route）</text>`;
  s2 += `<text x="${x0 - 40}" y="${TOP + panelH2 / 2}" text-anchor="middle" font-size="11.5" fill="${INK2}" transform="rotate(-90 ${x0 - 40} ${TOP + panelH2 / 2})">吞吐（NTT/s，@核 Fmax）</text>`;

  // 前沿连线
  s2 += `<polyline points="${KEY.map((k) => `${X(P.lut[k]).toFixed(1)},${Y(P.tputCore[k]).toFixed(1)}`).join(' ')}" fill="none" stroke="${MUTED2}" stroke-width="1.2" stroke-dasharray="4 3"/>`;
  const pwMin = Math.min(...KEY.map((k) => P.powerBoost[k]));
  const pwMax = Math.max(...KEY.map((k) => P.powerBoost[k]));
  KEY.forEach((k) => {
    const cx = X(P.lut[k]), cy = Y(P.tputCore[k]);
    const r = 6 + 11 * (P.powerBoost[k] - pwMin) / (pwMax - pwMin || 1);
    s2 += `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${r.toFixed(1)}" fill="${COL[k]}" fill-opacity="0.75" stroke="${COL[k]}" stroke-width="1.5"/>`;
    const right = k !== 'pe16';
    const tx = right ? cx + r + 6 : cx - r - 6;
    const anchor = right ? 'start' : 'end';
    s2 += `<text x="${tx.toFixed(1)}" y="${(cy - 2).toFixed(1)}" text-anchor="${anchor}" font-size="11" font-weight="600" fill="${INK2}">${k}</text>`;
    s2 += `<text x="${tx.toFixed(1)}" y="${(cy + 11).toFixed(1)}" text-anchor="${anchor}" font-size="9.5" fill="${MUTED2}">${fmt2(P.powerBoost[k], 3)} W（估算）</text>`;
  });
}

/* ---- 面板 2：ATP ------------------------------------------------------- */
{
  const pi = 1, x0 = px(pi);
  title2(pi, 'ATP = LUT × 周期', '面积 × 时间，越小越好');
  const atpMax = Math.ceil(Math.max(...KEY.map((k) => P.atp[k])) / 200000) * 200000;
  const slot = panelW2 / 3;
  const barW = slot * 0.52;
  for (let i = 0; i <= 4; i++) {
    const v = (atpMax / 4) * i;
    const y = BASE - (v / atpMax) * (panelH2 - 24);
    s2 += `<line x1="${x0}" y1="${y.toFixed(1)}" x2="${x0 + panelW2}" y2="${y.toFixed(1)}" stroke="${GRID2}"/>`;
    s2 += `<text x="${x0 - 6}" y="${(y + 4).toFixed(1)}" text-anchor="end" font-size="10" fill="${MUTED2}">${v === 0 ? '0' : (v / 1000).toFixed(0) + 'k'}</text>`;
  }
  KEY.forEach((k, ki) => {
    const v = P.atp[k];
    const h = (v / atpMax) * (panelH2 - 24);
    const cx = x0 + slot * (ki + 0.5);
    const low = k === 'pe4';
    s2 += `<rect x="${(cx - barW / 2).toFixed(1)}" y="${(BASE - h).toFixed(1)}" width="${barW.toFixed(1)}" height="${h.toFixed(1)}" rx="2" fill="${low ? '#c0392b' : COL[k]}"/>`;
    s2 += `<text x="${cx.toFixed(1)}" y="${(BASE - h - 8).toFixed(1)}" text-anchor="middle" font-size="11.5" font-weight="600" fill="${INK2}">${fmt2(v)}</text>`;
    s2 += `<text x="${cx.toFixed(1)}" y="${BASE + 16}" text-anchor="middle" font-size="12" fill="${INK2}">${k}</text>`;
    s2 += `<text x="${cx.toFixed(1)}" y="${BASE + 32}" text-anchor="middle" font-size="10" fill="${MUTED2}">${fmt2(P.atpNorm[k], 3)}× pe1</text>`;
    if (low) {
      s2 += `<text x="${cx.toFixed(1)}" y="${TOP + 14}" text-anchor="middle" font-size="10.5" font-weight="600" fill="#c0392b">最低</text>`;
    }
  });
  s2 += `<line x1="${x0}" y1="${BASE}" x2="${x0 + panelW2}" y2="${BASE}" stroke="${AXIS2}"/>`;
  s2 += `<text x="${x0 + panelW2 / 2}" y="${BASE + 54}" text-anchor="middle" font-size="11.5" fill="${INK2}">LUT·cycle</text>`;
}

/* ---- 面板 3：roofline（log-log） --------------------------------------- */
{
  const pi = 2, x0 = px(pi);
  title2(pi, 'Roofline：核要的带宽 vs 串口给的', '每趟 #NTT = 2124 B；双对数');
  const LX = (v) => Math.log10(v), LY = (v) => Math.log10(v);
  const xMin = 1e3, xMax = 1e10, yMin = 1, yMax = 1e7;
  const X = (v) => x0 + (LX(v) - LX(xMin)) / (LX(xMax) - LX(xMin)) * panelW2;
  const Y = (v) => BASE - (LY(v) - LY(yMin)) / (LY(yMax) - LY(yMin)) * panelH2;

  for (let e = 3; e <= 10; e++) {
    const x = X(10 ** e);
    s2 += `<line x1="${x.toFixed(1)}" y1="${TOP}" x2="${x.toFixed(1)}" y2="${BASE}" stroke="${GRID2}"/>`;
    s2 += `<text x="${x.toFixed(1)}" y="${BASE + 16}" text-anchor="middle" font-size="9.5" fill="${MUTED2}">${e === 3 ? '1k' : e === 6 ? '1M' : e === 9 ? '1G' : '10^' + e}</text>`;
  }
  for (let e = 0; e <= 6; e++) {
    const y = Y(10 ** e);
    s2 += `<line x1="${x0}" y1="${y.toFixed(1)}" x2="${x0 + panelW2}" y2="${y.toFixed(1)}" stroke="${GRID2}"/>`;
    s2 += `<text x="${x0 - 6}" y="${(y + 3.5).toFixed(1)}" text-anchor="end" font-size="9.5" fill="${MUTED2}">${e === 0 ? '1' : e === 3 ? '1k' : e === 6 ? '1M' : '10^' + e}</text>`;
  }
  s2 += `<line x1="${x0}" y1="${BASE}" x2="${x0 + panelW2}" y2="${BASE}" stroke="${AXIS2}"/>`;
  s2 += `<line x1="${x0}" y1="${TOP}" x2="${x0}" y2="${BASE}" stroke="${AXIS2}"/>`;
  s2 += `<text x="${x0 + panelW2 / 2}" y="${BASE + 36}" text-anchor="middle" font-size="11.5" fill="${INK2}">可用带宽（B/s）</text>`;
  s2 += `<text x="${x0 - 40}" y="${TOP + panelH2 / 2}" text-anchor="middle" font-size="11.5" fill="${INK2}" transform="rotate(-90 ${x0 - 40} ${TOP + panelH2 / 2})">事务率（NTT/s）</text>`;

  // 带宽屋顶 y = x / 2124
  const xa = 2124, xb = Math.min(xMax, 2124 * yMax);
  s2 += `<line x1="${X(xa).toFixed(1)}" y1="${Y(1).toFixed(1)}" x2="${X(xb).toFixed(1)}" y2="${Y(xb / 2124).toFixed(1)}" stroke="${MUTED2}" stroke-width="1.6"/>`;
  s2 += `<text x="${X(2e6).toFixed(1)}" y="${(Y(2e6 / 2124) - 8).toFixed(1)}" font-size="9.5" fill="${MUTED2}">带宽屋顶 y = x ÷ 2124 B</text>`;

  // 链路点
  [['115200', P.link115.pe1, 11520], ['921600', P.link921.pe1, 92160]].forEach(([name, v, bw]) => {
    const x = X(bw), y = Y(v);
    s2 += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="4.5" fill="#c0392b"/>`;
    s2 += `<text x="${(x + 7).toFixed(1)}" y="${(y + 3).toFixed(1)}" font-size="9.5" fill="#c0392b">${name}：${fmt2(v, 2)} NTT/s</text>`;
  });

  // 核点 + 计算屋顶
  KEY.forEach((k) => {
    const x = X(P.bwReqMB[k] * 1e6), y = Y(P.tputBoard[k]);
    s2 += `<line x1="${x.toFixed(1)}" y1="${y.toFixed(1)}" x2="${x0 + panelW2}" y2="${y.toFixed(1)}" stroke="${COL[k]}" stroke-width="1.1" stroke-dasharray="5 3" opacity="0.8"/>`;
    s2 += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="5" fill="${COL[k]}"/>`;
    s2 += `<text x="${(x - 5).toFixed(1)}" y="${(y - 8).toFixed(1)}" text-anchor="end" font-size="10" font-weight="600" fill="${COL[k]}">${k}</text>`;
  });
  s2 += `<text x="${(x0 + 4).toFixed(1)}" y="${(TOP + 14).toFixed(1)}" font-size="9" fill="${MUTED2}">计算屋顶（各档）</text>`;

  s2 += `<text x="${(x0 + panelW2 * 0.42).toFixed(1)}" y="${(BASE - 8).toFixed(1)}" font-size="10" font-weight="600" fill="#c0392b">← 串口给不起</text>`;
}

// 底部图例与出处
s2 += `<text x="${PP.l}" y="${PH - 30}" font-size="11" fill="${MUTED2}">` +
  `ATP 最低：pe4（${fmt2(P.atpNorm.pe4, 3)}× pe1）｜ 要喂满 pe1 需 ${fmt2(P.bwReqMB.pe1, 1)} MB/s，115200 只给 0.0115 MB/s（差 ${fmt2(P.tputBoard.pe1 / P.link115.pe1)}×）</text>`;
s2 += `<text x="${PP.l}" y="${PH - 12}" font-size="10.5" fill="${MUTED2}">` +
  `数据：metrics/data/pareto.csv（node metrics/gen_pareto.mjs）｜ 吞吐 @核 Fmax 为工具推算，@板上提频为 MMCM 位流实测；功耗为估算</text>`;
s2 += `</svg>\n`;

const outPareto = path.join(here, 'pareto_atp_roofline.svg');
fs.writeFileSync(outPareto, s2, 'utf8');
console.log(`写出 ${path.relative(process.cwd(), outPareto)}（${s2.length} 字节）`);
