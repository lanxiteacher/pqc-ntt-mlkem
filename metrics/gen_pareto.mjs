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
 * 定义（写死在这里，正文与图都引用同一套）：
 *   LUT·cycle      = LUT × NTT 周期数           （面积 × 周期，不是面积 × 时间）
 *   LUT·µs         = LUT × (周期数 ÷ 板上频率)   （面积 × 计算时间；按各档实际频率）
 *   ① 纯计算吞吐上限 = 频率 ÷ NTT 周期数          （只覆盖计算窗口，不含装载/读出）
 *   ② 装载到读出上限 = 频率 ÷ (256 + 周期数 + 256)（1 系数/拍、不重叠、无控制开销的延迟下界 / 吞吐上界）
 *   带宽需求        = 事务率 × 每趟事务字节数      （B/s；字节数取线上真实值 2124 B）
 *   链路事务率上限   = 波特率 ÷ 10 ÷ 每趟字节数     （8N1，10 bit/字节）
 *
 * ⚠️ 纯计算上限与装载到读出上限是两种边界；对外称「吞吐」时一律带边界名。
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
    const tputBoard = r.boardMHz * 1e6 / r.cycles;  // 实测频率：提频位流，纯计算窗口
    const ioCycles = 256 + r.cycles + 256;          // 装载 + 计算 + 读出（不重叠）
    const tputSustained = r.boardMHz * 1e6 / ioCycles;
    rows[t] = {
        ...r,
        atp,
        atpNorm: atp / atpRef,
        lutUs: r.lut * r.cycles / r.boardMHz,       // LUT·µs：LUT × 计算时间
        tputCore,
        tputBoard,
        tputSustained,
        bwReq: tputBoard * BYTES.ntt,               // B/s（按纯计算上限）
        bwReqSustained: tputSustained * BYTES.ntt,  // B/s（按装载到读出上限）
        powerBase: POWER[t]?.base,
        powerBoost: POWER[t]?.boost
    };
}
const lutUsRef = rows.pe1?.lutUs;
for (const t of TIERS) if (rows[t]) rows[t].lutUsNorm = rows[t].lutUs / lutUsRef;

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
        '面积 × 周期；与频率无关，越小越好。只计 LUT 不含 DSP/BRAM/FF', '本表 LUT × 周期'],
    ['ATP 归一（pe1 = 1）', ...TIERS.map((t) => num(rows[t].atpNorm, 3)), '×',
        'ATP ÷ pe1 的 ATP', '本表'],
    ['LUT·µs @板上提频', ...TIERS.map((t) => num(rows[t].lutUs, 0)), 'LUT·µs',
        'LUT × 计算时间（周期数 ÷ 该档板上频率）；只计计算窗口', 'board_freq_sweep.md'],
    ['LUT·µs 归一（pe1 = 1）', ...TIERS.map((t) => num(rows[t].lutUsNorm, 3)), '×',
        'LUT·µs ÷ pe1；按各档实际工作频率复算', '本表'],
    ['纯计算吞吐上限 @核推算 Fmax', ...TIERS.map((t) => num(rows[t].tputCore)), 'NTT/s',
        'Fmax(核) ÷ 周期；只覆盖计算窗口。Fmax 是 5 ns 收紧约束反推值', 'metrics/data/metrics.csv'],
    ['纯计算吞吐上限 @板上提频', ...TIERS.map((t) => num(rows[t].tputBoard)), 'NTT/s',
        '板上 MMCM 频率 ÷ 周期；只覆盖计算窗口 不含装载/读出', 'board_freq_sweep.md'],
    ['装载到读出上限 @板上提频', ...TIERS.map((t) => num(rows[t].tputSustained)), 'NTT/s',
        '频率 ÷ (256 + 周期数 + 256)；1 系数/拍 不重叠 无控制开销；延迟下界 / 吞吐上界', '本表（模型）'],
    ['维持纯计算上限所需带宽', ...TIERS.map((t) => num(rows[t].bwReq / 1e6, 1)), 'MB/s',
        '纯计算吞吐上限 × 2124 B（每趟 #NTT 的线上真实字节）', 'high_baud_demo.md'],
    ['维持装载到读出上限所需带宽', ...TIERS.map((t) => num(rows[t].bwReqSustained / 1e6, 1)), 'MB/s',
        '装载到读出上限 × 2124 B', '本表（模型）'],
    ['链路事务率上限 @115200', ...TIERS.map(() => num(LINK.uart115200, 2)), 'NTT/s',
        '115200 ÷ 10 ÷ 2124 B', 'bottleneck.csv / high_baud_demo.md'],
    ['链路事务率上限 @921600', ...TIERS.map(() => num(LINK.uart921600, 2)), 'NTT/s',
        '921600 ÷ 10 ÷ 2124 B', 'high_baud_demo.md'],
    ['纯计算上限 / 链路倍差 @115200', ...TIERS.map((t) => num(rows[t].tputBoard / LINK.uart115200)), '×',
        '纯计算吞吐上限 ÷ 链路事务率上限；上界口径', '本表'],
    ['纯计算上限 / 链路倍差 @921600', ...TIERS.map((t) => num(rows[t].tputBoard / LINK.uart921600)), '×',
        '纯计算吞吐上限 ÷ 链路事务率上限；上界口径', '本表'],
    ['装载到读出上限 / 链路倍差 @115200', ...TIERS.map((t) => num(rows[t].tputSustained / LINK.uart115200)), '×',
        '装载到读出上限 ÷ 链路事务率上限；吞吐上界口径', '本表'],
    ['装载到读出上限 / 链路倍差 @921600', ...TIERS.map((t) => num(rows[t].tputSustained / LINK.uart921600)), '×',
        '装载到读出上限 ÷ 链路事务率上限；吞吐上界口径', '本表'],
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
const minLutUs = TIERS.reduce((a, b) => (rows[a].lutUs <= rows[b].lutUs ? a : b));
const gapsS = TIERS.map((t) => rows[t].tputSustained / LINK.uart115200);
const minGapS = Math.min(...gapsS);
const maxGapS = Math.max(...gapsS);

const GEN = [
    '<!-- 这一段由 `node metrics/gen_pareto.mjs` 生成，别手改 -->',
    '',
    '### Pareto / LUT·cycle / roofline（2026-10-22 口径修订）',
    '',
    '| 档 | 周期 | LUT | **LUT·cycle** | 归一 | **LUT·µs @板上提频** | 归一 | 功耗（估算） |',
    '|---|---:|---:|---:|---:|---:|---:|---:|',
    ...TIERS.map((t) => {
        const r = rows[t];
        return `| ${t}（${PE_LABEL[t]}） | ${r.cycles} | ${r.lut} | **${r.atp.toLocaleString('en-US')}** | ` +
            `${f(r.atpNorm, 3)}× | ${fmtNum(r.lutUs, 0)} | ${f(r.lutUsNorm, 3)}× | ` +
            `${r.powerBase} / ${r.powerBoost} W |`;
    }),
    '',
    `**两种面积–时间指标都指向 ${minAtp}**（LUT·cycle ${f(rows[minAtp].atpNorm, 3)}× pe1、` +
        `LUT·µs ${f(rows[minLutUs].lutUsNorm, 3)}× pe1），但结论只对**这三个已测配置、只计 LUT** 成立；` +
        `DSP / BRAM / FF 未计入（见报告 §3.3 主表）。LUT·cycle 是面积 × 周期，与频率无关；` +
        `LUT·µs 按各档实际工作频率复算，排名可能与 LUT·cycle 不同 —— 引用时必须说明用哪一种。`,
    '',
    '**两种吞吐边界**（每趟 `#NTT` 线上 **2124 B**，8N1 = 10 bit/字节）：',
    '',
    '| 档 | ① 纯计算上限 @板上提频 | ② 装载→读出上限 @板上提频 | ② 所需带宽 | ② / 115200 | ② / 921600 |',
    '|---|---:|---:|---:|---:|---:|',
    ...TIERS.map((t) => {
        const r = rows[t];
        return `| ${t} | ${Math.round(r.tputBoard).toLocaleString('en-US')} NTT/s | ` +
            `${Math.round(r.tputSustained).toLocaleString('en-US')} NTT/s | ` +
            `${fmtNum(r.bwReqSustained / 1e6, 1)} MB/s | ` +
            `${fmtNum(r.tputSustained / LINK.uart115200)}× | ${fmtNum(r.tputSustained / LINK.uart921600)}× |`;
    }),
    '',
    '① = 频率 ÷ 周期数，**只覆盖计算窗口**；② = 频率 ÷ (256 + 周期数 + 256)，' +
        '假设装载/读出各 1 系数/拍、与计算不重叠、不计控制开销，**是延迟下限，对应吞吐上限**。',
    '真实串口事务另见报告 §3.10.3 / §3.10.4（pe1 实测 0.250 s @115200、0.079 s @921600）。',
    '',
    `- **链路屋顶**：115200 = **${f(LINK.uart115200, 2)} NTT/s**，921600 = **${f(LINK.uart921600, 2)} NTT/s**（÷10 bit ÷2124 B）。`,
    `- **带宽需求可复算**（按 ②）：三档需 ${TIERS.map((t) => `${t} ${fmtNum(rows[t].bwReqSustained / 1e6, 1)} MB/s`).join(' / ')}；` +
        `115200 只给 0.0115 MB/s、921600 只给 0.0922 MB/s —— 差 **${fmtNum(minGapS)}–${fmtNum(maxGapS)}×**（115200）。`,
    `- **装载/读出把深档位拉平**：pe16 的 ① 是 pe1 的 ${f(rows.pe16.tputBoard / rows.pe1.tputBoard, 1)}×，` +
        `到 ② 只剩 ${f(rows.pe16.tputSustained / rows.pe1.tputSustained, 2)}× —— 折叠越深，256 拍装载 + 256 拍读出越占主导。`,
    `- **Pareto**：按 ② 三档仍互不支配；选档看约束 —— 要面积选 pe1，要 LUT·cycle 最低选 ${minAtp}，要最低延迟选 pe16。`,
    '',
    '> ⚠️ **功耗列是 vectorless 估算**（Confidence Medium、25 °C、只算片内 PL），不是实测。',
    '> ⚠️ **频率两套**：`@核 Fmax` 是 post-route 推算（5 ns 约束反推），`@板上提频` 是 MMCM 位流真跑通的频率；**两者不能互相替代**。',
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
    console.log(`    ${t.padEnd(4)} LUT·cycle ${String(r.atp).padStart(9)} (${f(r.atpNorm, 3)}×)  ` +
        `LUT·µs ${String(f(r.lutUs, 0)).padStart(7)} (${f(r.lutUsNorm, 3)}×)  ` +
        `① ${String(Math.round(r.tputBoard)).padStart(7)} ② ${String(Math.round(r.tputSustained)).padStart(6)} NTT/s  ` +
        `②需 ${String(f(r.bwReqSustained / 1e6, 1)).padStart(6)} MB/s`);
}
console.log(`  链路屋顶：115200 = ${f(LINK.uart115200, 2)} NTT/s，921600 = ${f(LINK.uart921600, 2)} NTT/s（2124 B/趟）`);
console.log(`  ATP 最低：${minAtp}（${f(rows[minAtp].atpNorm, 3)}× pe1）`);
console.log('  ✅ 写出 metrics/data/pareto.csv 并更新 metrics/README.md 的 GEN:PARETO 块');
