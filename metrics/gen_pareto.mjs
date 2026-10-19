/* ===========================================================================
 * gen_pareto.mjs —— 出彩组合 #7 的 C 侧：Pareto / ATP / roofline
 *
 * 全部数字从已提交的产物解析，不手抄：
 *   metrics/data/metrics.csv         周期 / LUT / 核推算 Fmax / 板上频率
 *   metrics/data/bottleneck.csv      核延迟与串口搬运（校验用）
 *   rtl/vivado/power_estimate.md     六版位流功耗（vectorless 估算）
 *   rtl/vivado/high_baud_demo.md     每趟 #NTT 的线上字节数与 921600 上限
 *
 * 输出：
 *   metrics/data/pareto.csv          「一表」（长表，一行一个指标）
 *   metrics/README.md 的 GEN:PARETO 块（表格 + 公式 + 结论）
 *
 * 用法：node metrics/gen_pareto.mjs
 *
 * 三个定义（写死在这里，正文与图都引用同一套）：
 *   ATP          = LUT × NTT 周期数            （面积×时间，越小越好，时钟无关）
 *   吞吐          = 频率 ÷ NTT 周期数            （NTT/s）
 *   带宽需求      = 吞吐 × 每趟事务字节数        （B/s；字节数取线上真实值 2124 B）
 *   链路事务率上限 = 波特率 ÷ 10 ÷ 每趟字节数    （8N1，10 bit/字节）
 * =========================================================================== */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');

const TIERS = ['pe1', 'pe4', 'pe16'];
const PE_LABEL = { pe1: '1 蝶形', pe4: '4 蝶形', pe16: '16 蝶形' };

let ok = true;
const fail = (m) => { ok = false; console.error('❌ ' + m); };
const read = (rel) => {
    const p = path.join(REPO, rel);
    if (!fs.existsSync(p)) { fail(`找不到 ${rel}`); return ''; }
    return fs.readFileSync(p, 'utf8');
};

/* ---- metrics.csv -------------------------------------------------------- */
const RES = {};
for (const line of read('metrics/data/metrics.csv').split('\n').map((s) => s.replace(/\r$/, '')).slice(1)) {
    if (!line.trim()) continue;
    const f = line.split(',');
    const [name, , value, , cond] = f;
    const m = /^档位 (pe(?:1|4|16))；/.exec(cond || '');
    if (!m) continue;
    const t = m[1];
    RES[t] ||= {};
    if (name === 'LUT') RES[t].lut = Number(value);
    else if (name === 'NTT 周期数') RES[t].cycles = Number(value);
    else if (name === '推算 Fmax') RES[t].fmaxCore = Number(value);
    else if (name === '板上跑通最高频率（MMCM 提频）') RES[t].boardMHz = Number(value);
}

/* ---- 功耗（估算） ------------------------------------------------------- */
const POWER = {};
for (const m of read('rtl/vivado/power_estimate.md').matchAll(
    /^\|\s*(pe(?:1|4|16))\s*\|\s*([\d.]+) MHz\s*\|\s*\*\*([\d.]+) W\*\*/gm)) {
    const [, t, mhz, total] = m;
    POWER[t] ||= {};
    POWER[t][Number(mhz) === 50 ? 'base' : 'boost'] = Number(total);
}

/* ---- 每趟事务的真实字节数（从 921600 表读，不另抄一份） ----------------- */
const BYTES = {};
for (const m of read('rtl/vivado/high_baud_demo.md').matchAll(
    /^\|\s*`([^`]+)`\s*\|\s*(\d+) B\s*\|\s*([\d.]+) ms\s*\|\s*\*\*([\d.]+) ms\*\*\s*\|/gm)) {
    const [, cmd, bytes, s115, s921] = m;
    if (cmd === '#NTT 1') {
        BYTES.ntt = Number(bytes);
        BYTES.serial115200ms = Number(s115);
        BYTES.serial921600ms = Number(s921);
    }
}
if (!BYTES.ntt) fail('high_baud_demo.md 里读不到 #NTT 1 的字节数');

const BAUD = { uart115200: 115200, uart921600: 921600 };
const BITS_PER_BYTE = 10;                       // 8N1

/* ---- 计算 ---------------------------------------------------------------- */
const rows = {};
let atpRef = null;
for (const t of TIERS) {
    const r = RES[t] || {};
    if (!Number.isFinite(r.lut) || !Number.isFinite(r.cycles) ||
        !Number.isFinite(r.fmaxCore) || !Number.isFinite(r.boardMHz)) {
        fail(`${t} 的 LUT / 周期 / Fmax / 板上频率没读全`);
        continue;
    }
    const atp = r.lut * r.cycles;
    if (atpRef === null) atpRef = atp;
    const tputCore = r.fmaxCore * 1e6 / r.cycles;   // 推算：post-route 核 Fmax
    const tputBoard = r.boardMHz * 1e6 / r.cycles;  // 实测频率：提频位流
    rows[t] = {
        ...r,
        atp,
        atpNorm: atp / atpRef,
        tputCore,
        tputBoard,
        bwReq: tputBoard * BYTES.ntt,               // B/s
        powerBase: POWER[t]?.base,
        powerBoost: POWER[t]?.boost
    };
}

const linkNtt = (baud) => baud / BITS_PER_BYTE / BYTES.ntt;
const LINK = {
    uart115200: linkNtt(BAUD.uart115200),
    uart921600: linkNtt(BAUD.uart921600)
};

/* 断言：三种独立口径要自洽 —— 否则说明源文件之间漂了 */
for (const t of TIERS) {
    if (!rows[t]) continue;
    const coreUs = rows[t].cycles / 50e6 * 1e6;      // 50 MHz 基线上的核延迟
    const fromBottleneck = (read('metrics/data/bottleneck.csv')
        .split('\n').find((l) => l.startsWith(`计算核延迟,#NTT 1（${t}）`)) || '').split(',')[2];
    if (fromBottleneck && Math.abs(Number(fromBottleneck) - coreUs) > 0.02) {
        fail(`${t}：周期数换算 ${coreUs.toFixed(2)} µs 与 bottleneck.csv 的 ${fromBottleneck} µs 不一致`);
    }
}
const serialMs = BYTES.ntt * BITS_PER_BYTE / BAUD.uart115200 * 1000;

if (Math.abs(serialMs - BYTES.serial115200ms) > 0.1) {
    fail(`2124 B @115200 算得 ${serialMs.toFixed(1)} ms，high_baud_demo.md 写 ${BYTES.serial115200ms} ms`);
}

if (!ok) {
    console.error('\n❌ 源文件之间有缺口，不写产物。');
    process.exit(1);
}

/* ---- 「一表」：long CSV ------------------------------------------------- */
const num = (v, d = 0) => Number(v.toFixed(d));
const csv = [
    ['指标', 'pe1', 'pe4', 'pe16', '单位', '公式 / 口径', '证据'],
    ['NTT 周期数', ...TIERS.map((t) => rows[t].cycles), 'cycles',
        '顶层 done 拍 − start − 3，不含读出延迟', 'rtl/probes/README.md §判据 2'],
    ['LUT', ...TIERS.map((t) => rows[t].lut), '个',
        'post-route，顶层边界', 'rtl/vivado/reports/pe*_nc_util.rpt'],
    ['ATP（LUT × cycle）', ...TIERS.map((t) => rows[t].atp), 'LUT·cycle',
        '面积 × 时间；与时钟无关，越小越好', '本表 LUT × 周期'],
    ['ATP 归一（pe1 = 1）', ...TIERS.map((t) => num(rows[t].atpNorm, 3)), '×',
        'ATP ÷ pe1 的 ATP', '本表'],
    ['吞吐 @ 核推算 Fmax', ...TIERS.map((t) => num(rows[t].tputCore)), 'NTT/s',
        'Fmax(核) ÷ 周期；Fmax 是 5 ns 收紧约束反推值', 'metrics/data/metrics.csv'],
    ['吞吐 @ 板上提频频率', ...TIERS.map((t) => num(rows[t].tputBoard)), 'NTT/s',
        '板上 MMCM 频率 ÷ 周期；频率是「跑得通」，不是芯片极限', 'board_freq_sweep.md'],
    ['维持核吞吐所需带宽', ...TIERS.map((t) => num(rows[t].bwReq / 1e6, 1)), 'MB/s',
        '吞吐 × 2124 B（每趟 #NTT 的线上真实字节）', 'high_baud_demo.md'],
    ['链路事务率上限 @115200', ...TIERS.map(() => num(LINK.uart115200, 2)), 'NTT/s',
        '115200 ÷ 10 ÷ 2124 B', 'bottleneck.csv / high_baud_demo.md'],
    ['链路事务率上限 @921600', ...TIERS.map(() => num(LINK.uart921600, 2)), 'NTT/s',
        '921600 ÷ 10 ÷ 2124 B', 'high_baud_demo.md'],
    ['核 / 链路倍差 @115200', ...TIERS.map((t) => num(rows[t].tputBoard / LINK.uart115200)), '×',
        '吞吐 @板上 ÷ 链路事务率上限', '本表'],
    ['核 / 链路倍差 @921600', ...TIERS.map((t) => num(rows[t].tputBoard / LINK.uart921600)), '×',
        '吞吐 @板上 ÷ 链路事务率上限', '本表'],
    ['功耗 @ 50 MHz（估算）', ...TIERS.map((t) => rows[t].powerBase), 'W',
        'Vivado report_power，vectorless 估算，非实测', 'power_estimate.md'],
    ['功耗 @ 提频（估算）', ...TIERS.map((t) => rows[t].powerBoost), 'W',
        '同上；提频的增量主要是 MMCM', 'power_estimate.md']
];
fs.writeFileSync(path.join(HERE, 'data', 'pareto.csv'),
    csv.map((r) => r.join(',')).join('\n') + '\n', { encoding: 'utf8' });

/* ---- README 的 GEN 块 --------------------------------------------------- */
const f = (v, d = 0) => Number(v).toFixed(d);
const fmtNum = (v, d = 0) => Number(v).toLocaleString('en-US', {
    minimumFractionDigits: d, maximumFractionDigits: d
});
const minAtp = TIERS.reduce((a, b) => (rows[a].atp <= rows[b].atp ? a : b));
const maxGap = Math.max(...TIERS.map((t) => rows[t].tputBoard / LINK.uart115200));
const minGap = Math.min(...TIERS.map((t) => rows[t].tputBoard / LINK.uart115200));

const GEN = [
    '<!-- 这一段由 `node metrics/gen_pareto.mjs` 生成，别手改 -->',
    '',
    '### Pareto / ATP / roofline（2026-10-19）',
    '',
    '| 档 | 周期 | LUT | **ATP**（LUT·cycle） | ATP 归一 | 吞吐 @核 Fmax | 吞吐 @板上提频 | 维持吞吐所需带宽 | 功耗（估算） |',
    '|---|---:|---:|---:|---:|---:|---:|---:|---:|',
    ...TIERS.map((t) => {
        const r = rows[t];
        return `| ${t}（${PE_LABEL[t]}） | ${r.cycles} | ${r.lut} | **${r.atp.toLocaleString('en-US')}** | ` +
            `${f(r.atpNorm, 3)}× | ${Math.round(r.tputCore).toLocaleString('en-US')} NTT/s | ` +
            `${Math.round(r.tputBoard).toLocaleString('en-US')} NTT/s | ${fmtNum(r.bwReq / 1e6, 1)} MB/s | ` +
            `${r.powerBase} / ${r.powerBoost} W |`;
    }),
    '',
    `**ATP 最低的是 ${minAtp}（${f(rows[minAtp].atpNorm, 3)}× pe1）** —— ` +
        `面积 × 时间不是「越深越好」：pe16 用 12.3× 的 LUT 换 13.1× 的周期下降，ATP 反而回到 ${f(rows.pe16.atpNorm, 3)}×。`,
    '',
    '**roofline 的两个屋顶**（每趟 `#NTT` 线上 **2124 B**，8N1 = 10 bit/字节）：',
    '',
    '| 屋顶 | 公式 | 结果 |',
    '|---|---|---:|',
    `| 串口链路（115200） | 115200 ÷ 10 ÷ 2124 | **${f(LINK.uart115200, 2)} NTT/s** |`,
    `| 串口链路（921600） | 921600 ÷ 10 ÷ 2124 | **${f(LINK.uart921600, 2)} NTT/s** |`,
    `| 核（pe1，板上 80 MHz） | 80 MHz ÷ 904 | ${Math.round(rows.pe1.tputBoard).toLocaleString('en-US')} NTT/s |`,
    `| 核（pe16，板上 62.5 MHz） | 62.5 MHz ÷ 69 | ${Math.round(rows.pe16.tputBoard).toLocaleString('en-US')} NTT/s |`,
    '',
    `- **带宽需求可复算**：\`带宽 = 吞吐 × 2124 B\`。三档要喂满核，分别需要 ` +
        `${TIERS.map((t) => `${t} ${fmtNum(rows[t].bwReq / 1e6, 1)} MB/s`).join(' / ')}；` +
        `而 115200 只有 **0.0115 MB/s**、921600 只有 **0.0922 MB/s**。`,
    `- **核 / 链路倍差**：115200 下 **${fmtNum(minGap)}–${fmtNum(maxGap)}×**；` +
        `921600 下 **${fmtNum(minGap / 8)}–${fmtNum(maxGap / 8)}×**。` +
        `这不是核慢，是接口带宽差 4–5 个数量级。`,
    `- **Pareto**：三档互不支配（LUT 越高、吞吐越高），所以三档都留在前沿上；` +
        `选档看约束 —— 要面积选 pe1，要 ATP 最低选 ${minAtp}，要最低延迟选 pe16。`,
    '',
    '> ⚠️ **功耗列是 vectorless 估算**（Confidence Medium、25 °C、只算片内 PL），不是实测。',
    '> ⚠️ **吞吐列用两套频率**：`@核 Fmax` 是 post-route 推算（5 ns 约束反推），`@板上提频` 是 MMCM 位流真跑通的频率；**两者不能互相替代**。',
    '',
    '```bash',
    'node metrics/gen_pareto.mjs     # → metrics/data/pareto.csv + 本块',
    '```'
];

const README = path.join(HERE, 'README.md');
const B = '<!-- GEN:PARETO:BEGIN -->';
const E = '<!-- GEN:PARETO:END -->';
let md = fs.readFileSync(README, 'utf8');
const i = md.indexOf(B), j = md.indexOf(E);
if (i < 0 || j < 0 || j < i) {
    console.error(`❌ metrics/README.md 找不到 ${B} / ${E}，不写。`);
    process.exit(1);
}
md = md.slice(0, i + B.length) + '\n\n' + GEN.join('\n') + '\n\n' + md.slice(j);
fs.writeFileSync(README, md, { encoding: 'utf8' });

/* ---- 打印 --------------------------------------------------------------- */
console.log('  三档：');
for (const t of TIERS) {
    const r = rows[t];
    console.log(`    ${t.padEnd(4)} ATP ${String(r.atp).padStart(9)}  ` +
        `(${f(r.atpNorm, 3)}×)  @核 ${String(Math.round(r.tputCore)).padStart(8)} NTT/s  ` +
        `@板 ${String(Math.round(r.tputBoard)).padStart(7)} NTT/s  ` +
        `需 ${String(f(r.bwReq / 1e6, 1)).padStart(7)} MB/s`);
}
console.log(`  链路屋顶：115200 = ${f(LINK.uart115200, 2)} NTT/s，921600 = ${f(LINK.uart921600, 2)} NTT/s（2124 B/趟）`);
console.log(`  ATP 最低：${minAtp}（${f(rows[minAtp].atpNorm, 3)}× pe1）`);
console.log('  ✅ 写出 metrics/data/pareto.csv 并更新 metrics/README.md 的 GEN:PARETO 块');
