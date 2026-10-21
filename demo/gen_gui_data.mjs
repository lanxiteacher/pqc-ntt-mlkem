/* ===========================================================================
 * gen_gui_data.mjs —— 生成「现场演示」页面要的计时 / 资源数据
 *
 * 输入（全部是仓库里已提交的产物，**不手抄数字**）：
 *   metrics/data/metrics.csv        三档资源 / 推算 Fmax / 周期数 / 板上频率
 *   metrics/data/bottleneck.csv     核延迟、串口搬运、软件参考耗时
 *   rtl/vivado/power_estimate.md    六版位流功耗（vectorless 估算）
 *   rtl/vivado/high_baud_demo.md    115200 / 921600 线上与墙钟
 *   rtl/vivado/reports/board_*_txn.txt   板上 6 条命令的 PASS 数
 *
 * 输出：demo/data/gui.js —— 写成 .js 而不是 .json，file:// 双击才读得到
 *
 * 用法：node demo/gen_gui_data.mjs
 * =========================================================================== */

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');

const TIERS = ['pe1', 'pe4', 'pe16'];
const PE_NUM = { pe1: 1, pe4: 4, pe16: 16 };
const BOARD_TAG = { pe1: 'f80', pe4: 'f75', pe16: 'f62.5' };

let ok = true;
const fail = (m) => { ok = false; console.error('❌ ' + m); };

function readText(rel) {
    const p = path.join(REPO, rel);
    if (!fs.existsSync(p)) { fail(`找不到 ${rel}`); return ''; }
    return fs.readFileSync(p, 'utf8');
}

/* ---- metrics.csv：长表，「档位 peN；」开头的行按档归组 ------------------ */
function parseCsvLine(line) {
    // 本仓库的 CSV 字段里没有 ASCII 逗号（口径里的分隔用全角「，」），直接 split 即可。
    return line.split(',');
}

const metricRows = readText('metrics/data/metrics.csv')
    .split('\n').map((s) => s.replace(/\r$/, '')).filter((s) => s.trim() !== '');

const RES = {};
const CYCLES = {};
const BOARD_FREQ = {};
const WNS = {};
const FMAX_CORE = {};

for (const line of metricRows) {
    const f = parseCsvLine(line);
    if (f.length < 5) continue;
    const [name, , value, , cond] = f;
    const m = /^档位 (pe(?:1|4|16))；/.exec(cond);
    if (!m) continue;
    const t = m[1];
    RES[t] ||= {};
    if (name === 'LUT') RES[t].lut = Number(value);
    else if (name === 'LUT 占用率') RES[t].lutPct = Number(value);
    else if (name === 'FF') RES[t].ff = Number(value);
    else if (name === 'DSP') RES[t].dsp = Number(value);
    else if (name === 'DSP 占用率') RES[t].dspPct = Number(value);
    else if (name === 'BRAM tile') RES[t].bramTile = Number(value);
    else if (name === 'IOB') RES[t].iob = Number(value);
    else if (name === 'WNS') WNS[t] = Number(value);
    else if (name === '推算 Fmax') FMAX_CORE[t] = Number(value);
    else if (name === 'NTT 周期数') CYCLES[t] = Number(value);
    else if (name === '板上跑通最高频率（MMCM 提频）') BOARD_FREQ[t] = Number(value);
}

/* ---- bottleneck.csv：核延迟 / 串口搬运 / 软件参考 ---------------------- */
const NK = {};
const SERIAL_115200 = {};
for (const line of readText('metrics/data/bottleneck.csv')
        .split('\n').map((s) => s.replace(/\r$/, '')).slice(1)) {
    if (!line.trim()) continue;
    const [seg, cmd, value, unit] = parseCsvLine(line);
    if (seg === '计算核延迟' && unit === 'µs') {
        const m = /（(pe(?:1|4|16))）/.exec(cmd);
        if (m) NK[m[1]] = Number(value);
    } else if (seg === '串口搬运' && unit === 'ms') {
        if (cmd === '#NTT 1') SERIAL_115200.ntt = Number(value);
        else if (cmd === '#PMUL NTT 1') SERIAL_115200.pmul = Number(value);
    } else if (seg === '软件参考实现') NK.softwareRefUs = Number(value);
    else if (seg === 'PC 侧软件开销') NK.pcOverheadMs = Number(value);
}

/* ---- high_baud_demo.md：921600 的线上与墙钟 ---------------------------- */
const HB = { serial921600: {}, wall115200: {}, wall921600: {}, onlineMultiple: null, wallMultiple: null };
for (const m of readText('rtl/vivado/high_baud_demo.md').matchAll(
    /^\|\s*`([^`]+)`\s*\|\s*[\d]+ B\s*\|\s*([\d.]+) ms\s*\|\s*\*\*([\d.]+) ms\*\*\s*\|\s*\*\*([\d.]+)×\*\*\s*\|\s*([\d.]+) s\s*\|\s*\*\*([\d.]+) s\*\*\s*\|\s*\*\*([\d.]+)×\*\*\s*\|/gm)) {
    const [, cmd, s115, s921, omul, w115, w921, wmul] = m;
    if (cmd === '#NTT 1') {
        HB.wall115200.ntt = Number(w115);
        HB.wall921600.ntt = Number(w921);
        HB.serial921600.ntt = Number(s921);
        HB.onlineMultiple = Number(omul);
        HB.wallMultiple = Number(wmul);
    } else if (cmd === '#PMUL NTT 1') {
        HB.wall115200.pmul = Number(w115);
        HB.wall921600.pmul = Number(w921);
        HB.serial921600.pmul = Number(s921);
    }
}
if (HB.wall921600.ntt === undefined) fail('high_baud_demo.md 里读不到 #NTT 1 那一行');

/* ---- power_estimate.md：三档 50 MHz 与提频功耗 ------------------------- */
const POWER = {};
for (const m of readText('rtl/vivado/power_estimate.md').matchAll(
    /^\|\s*(pe(?:1|4|16))\s*\|\s*([\d.]+) MHz\s*\|\s*\*\*([\d.]+) W\*\*\s*\|\s*([\d.]+) W\s*\|\s*([\d.]+) W\s*\|\s*([\d.]+) °C\s*\|\s*([^|]*?)\s*\|/gm)) {
    const [, t, mhz, total, dyn, stat, , mmcm] = m;
    POWER[t] ||= {};
    if (Number(mhz) === 50) {
        POWER[t].base = { total: Number(total), dynamic: Number(dyn), static: Number(stat) };
    } else {
        POWER[t].boost = {
            total: Number(total), dynamic: Number(dyn), static: Number(stat),
            mmcm: /\d/.test(mmcm) ? Number((mmcm.match(/[\d.]+/) || [0])[0]) : null
        };
    }
}

/* ---- 板上事务报告：数 PASS --------------------------------------------- */
function txnPass(rel) {
    const txt = readText(rel);
    if (!txt) return null;
    return (txt.match(/→\s*✅\s*PASS/g) || []).length;
}
const BOARD = {};
for (const t of TIERS) {
    BOARD[t] = {
        base: {
            pass: txnPass(`rtl/vivado/reports/board_${t}_txn.txt`),
            total: 6,
            evidence: `rtl/vivado/reports/board_${t}_txn.txt`
        },
        boosted: {
            pass: txnPass(`rtl/vivado/reports/board_${t}_${BOARD_TAG[t]}_txn.txt`),
            total: 6,
            evidence: `rtl/vivado/reports/board_${t}_${BOARD_TAG[t]}_txn.txt`
        }
    };
}

/* ---- 汇总 + 必需字段检查 ----------------------------------------------- */
const TIER_LABEL = { pe1: 'pe1 · 1 蝶形', pe4: 'pe4 · 4 蝶形', pe16: 'pe16 · 16 蝶形' };
const tiers = {};
for (const t of TIERS) {
    const r = RES[t] || {};
    const p = POWER[t] || {};
    if (!Number.isFinite(r.lut) || !Number.isFinite(CYCLES[t]) || !Number.isFinite(FMAX_CORE[t])) {
        fail(`${t} 的资源 / 周期 / Fmax 没读全`);
        continue;
    }
    tiers[t] = {
        key: t,
        label: TIER_LABEL[t],
        folds: PE_NUM[t],
        lut: r.lut, lutPct: r.lutPct, ff: r.ff,
        dsp: r.dsp, dspPct: r.dspPct,
        bramTile: r.bramTile, iob: r.iob,
        wns: WNS[t], fmaxCore: FMAX_CORE[t],
        cycles: CYCLES[t],
        coreUs: NK[t],
        speedup: +(CYCLES.pe1 / CYCLES[t]).toFixed(2),
        boardMHz: BOARD_FREQ[t],
        powerBase: p.base ? p.base.total : null,
        powerBoost: p.boost ? p.boost.total : null,
        powerMMCM: p.boost ? p.boost.mmcm : null,
        board: BOARD[t]
    };
}

/* 「数据截至」取输入文件最后一次提交的日期 —— 不用当天日期，否则每次重跑都会弄脏工作区，
 * 录制前的「生成器重跑后 git status 干净」体检就永远为假。 */
function dataAsOf() {
    try {
        const out = execSync(
            'git log -1 --format=%cs -- metrics/data/metrics.csv metrics/data/bottleneck.csv ' +
            'rtl/vivado/power_estimate.md rtl/vivado/high_baud_demo.md',
            { cwd: REPO, encoding: 'utf8' }
        ).trim();
        return out || 'unknown';
    } catch {
        return 'unknown';
    }
}

const payload = {
    meta: {
        generatedBy: 'demo/gen_gui_data.mjs（node）',
        dataAsOf: dataAsOf(),
        tierNote: '资源与推算 Fmax 为 post-route；板上频率是提频位流真板跑通的频率，不是芯片极限',
        powerNote: '功耗是 Vivado report_power 的 vectorless 估算（Confidence Medium，25 °C，只算片内 PL），不是实测',
        boardNote: '板上数据来自 2026-10-18 已提交的串口事务报告；本页面不连接开发板，按回放模式展示',
        sources: [
            'metrics/data/metrics.csv',
            'metrics/data/bottleneck.csv',
            'rtl/vivado/power_estimate.md',
            'rtl/vivado/high_baud_demo.md',
            'rtl/vivado/reports/board_pe{1,4,16}[_f*]_txn.txt'
        ]
    },
    tiers,
    tierOrder: TIERS,
    timing: {
        coreLatencyUs: { pe1: NK.pe1, pe4: NK.pe4, pe16: NK.pe16 },
        softwareRefUs: NK.softwareRefUs,
        pcOverheadMs: NK.pcOverheadMs,
        serial115200: SERIAL_115200,
        serial921600: HB.serial921600,
        wall115200: HB.wall115200,
        wall921600: HB.wall921600,
        onlineMultiple: HB.onlineMultiple,
        wallMultiple: HB.wallMultiple,
        pingRoundTripMs: 31
    }
};

if (!ok) {
    console.error('\n❌ 有字段没读全，不写产物。');
    process.exit(1);
}

const outDir = path.join(HERE, 'data');
fs.mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, 'gui.js');
fs.writeFileSync(outFile, 'window.GUI_DATA = ' + JSON.stringify(payload) + ';\n', { encoding: 'utf8' });

console.log('  三档：');
for (const t of TIERS) {
    const r = tiers[t];
    console.log(`    ${t.padEnd(4)} 周期 ${String(r.cycles).padStart(3)}  ` +
        `核 ${String(r.coreUs).padStart(5)} µs  LUT ${String(r.lut).padStart(4)}  ` +
        `DSP ${String(r.dsp).padStart(2)}  Fmax(核) ${r.fmaxCore} MHz  ` +
        `板上 ${r.boardMHz} MHz  功耗 ${r.powerBase} / ${r.powerBoost} W  ` +
        `板上 ${r.board.base.pass}/${r.board.base.total} + ${r.board.boosted.pass}/${r.board.boosted.total}`);
}
console.log(`  端到端：#NTT 115200 墙钟 ${HB.wall115200.ntt} s → 921600 ${HB.wall921600.ntt} s（${HB.wallMultiple}×）`);
console.log(`  线上搬运：${SERIAL_115200.ntt} ms → ${HB.serial921600.ntt} ms（${HB.onlineMultiple}×）`);
console.log(`  ✅ 写出 ${path.relative(REPO, outFile)}（LF 行尾）`);
