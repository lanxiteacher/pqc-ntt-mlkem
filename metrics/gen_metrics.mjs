/* ===========================================================================
 * gen_metrics.mjs —— 生成《选题指导》§8.3 要的指标汇总表
 *
 * 为什么要有这个脚本，而不是直接把数字写进 README：
 *   表里的 LUT / FF / DSP / BRAM / IOB / WNS 全部**从 Vivado 报告里解析**，
 *   不手抄。手抄过一次就会有过期不重抄的风险；解析出来的数字，
 *   只要重跑就自动跟着报告走。
 *
 *   生成的两张表写在 README.md 的 `<!-- GEN:BEGIN -->` 与 `<!-- GEN:END -->`
 *   之间，其余部分（说明、陷阱、待测项）是手写的，脚本不碰。
 *
 * 数据来源（**只读**，本脚本不改 rtl/ 下任何文件）：
 *   rtl/vivado/reports/pe{1,4,16}_nc_{util,timing}.rpt     参数化版（顶层边界）
 *   rtl/vivado/reports/pe{1,4,16}_utop_{util,timing}.rpt   上游顶层（同边界对照）
 *   rtl/probes/README.md §判据 2                       三档周期数
 *   refsim/README.md                                  功能正确性（B 侧）
 *
 * 用法：node metrics/gen_metrics.mjs
 * 产物：metrics/README.md（只更新 GEN 块）+ metrics/data/metrics.csv
 * =========================================================================== */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const RPT = path.join(REPO, 'rtl', 'vivado', 'reports');

const TIERS = ['pe1', 'pe4', 'pe16'];
const PE_NUM = { pe1: 1, pe4: 4, pe16: 16 };

let ok = true;
const fail = (m) => { ok = false; console.error('❌ ' + m); };

/* ---- 解析 Vivado 报告 -------------------------------------------------- */

const read = (p) => {
    if (!fs.existsSync(p)) { fail(`报告不存在：${path.relative(REPO, p)}`); return ''; }
    return fs.readFileSync(p, 'utf8');
};

/* `| Slice LUTs                 | 8922 |     0 |     53200 | 16.77 |`
 *  → used=8922，pct=16.77。同名表在报告里可能出现两次（不同小节），取第一处。
 * ⚠️ 只到综合的报告（如 pe16_utop）里写的是 `| Slice LUTs*`，多一个星号，
 *    所以标签后面要允许一个 `*`。 */
function utilField(text, label) {
    const re = new RegExp('\\|\\s+' + label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\*?' +
                          '\\s*\\|\\s*([\\d.]+)\\s*\\|\\s*\\d+\\s*\\|\\s*(\\d+)\\s*\\|\\s*([\\d.]+)\\s*\\|');
    const m = text.match(re);
    if (!m) { fail(`报告里找不到「${label}」那一行`); return null; }
    return { used: m[1], total: m[2], pct: m[3] };
}

function designState(text) {
    const m = text.match(/\| Design State\s*:\s*(.+?)\s*$/m);
    if (!m) { fail('报告里找不到 Design State'); return null; }
    return m[1].trim();
}

/* Design Timing Summary 的第一行数据：WNS / TNS / …… / WHS
 * ⚠️ 别用「以 - 开头就跳过」过滤横线行 —— **WNS 本身是负数，也以 - 开头**。
 *    这么写会把真正的数据行吃掉，然后一路扫到关键路径表里去，拿到一个正数。
 *    只跳过「整行都是横线」的行。 */
function timingSummary(text) {
    const i = text.indexOf('Design Timing Summary');
    if (i < 0) { fail('时序报告里找不到 Design Timing Summary'); return null; }
    for (const line of text.slice(i).split('\n')) {
        const t = line.trim();
        if (!t || t.startsWith('|')) continue;
        if (/^-+(\s+-+)*$/.test(t)) continue;        // 纯横线行
        if (t.startsWith('WNS(ns)')) continue;
        const nums = t.split(/\s+/);
        if (nums.length >= 5 && /^-?[\d.]+$/.test(nums[0]) && /^-?[\d.]+$/.test(nums[1])) {
            return { wns: nums[0], tns: nums[1], whs: nums[4] };
        }
    }
    fail('Design Timing Summary 里没找到数据行');
    return null;
}

function clockPeriod(text) {
    const m = text.match(/^clk\s+\{[^}]*\}\s+([\d.]+)\s+([\d.]+)\s*$/m);
    if (!m) fail('时钟摘要里没找到 clk 的周期');
    return m ? { period: m[1], freq: m[2] } : null;
}

/* Fmax 是反推的：约束故意给紧，所以 WNS 一定为负。
 * T_min ≈ 目标周期 − WNS，Fmax = 1000 / T_min。 */
function fmaxOf(period, wns) {
    const tmin = parseFloat(period) - parseFloat(wns);
    return Math.round(1000 / tmin);
}

function loadTier(tier, suffix) {
    const tag = suffix ? `${tier}_${suffix}` : tier;
    const u = read(path.join(RPT, `${tag}_util.rpt`));
    const t = read(path.join(RPT, `${tag}_timing.rpt`));
    if (!u || !t) return null;
    const ck = clockPeriod(t);
    const ts = timingSummary(t);
    return {
        tier,
        pe: PE_NUM[tier],
        reportTag: tag,
        state: designState(u),
        lut: utilField(u, 'Slice LUTs'),
        ff: utilField(u, 'Slice Registers'),
        dsp: utilField(u, 'DSPs'),
        bramTile: utilField(u, 'Block RAM Tile'),
        ramb18: utilField(u, 'RAMB18'),
        ramb36: utilField(u, 'RAMB36/FIFO'),
        iob: utilField(u, 'Bonded IOB'),
        wns: ts ? ts.wns : null,
        whs: ts ? ts.whs : null,
        period: ck ? ck.period : null,
        fmax: (ck && ts) ? fmaxOf(ck.period, ts.wns) : null
    };
}

const nc = {};    // 参数化版顶层（主表）—— 报告后缀 _nc
const utop = {};  // 上游顶层（同边界对照）—— 报告后缀 _utop
/* ⚠️ 后缀为空的那三份（pe1_util.rpt 等）量的是上游**核** KyberHPMNPE，
 * 不是顶层 —— 边界不同，不能拿来跟参数化版比。别把它们当成 utop。 */
for (const t of TIERS) {
    nc[t] = loadTier(t, 'nc');
    utop[t] = loadTier(t, 'utop');
}

/* ---- 非退化自查：这些列必须随折叠度单调上升，否则说明解析错了 ---------- */
for (const col of ['lut', 'ff', 'dsp']) {
    const vals = TIERS.map((t) => Number(nc[t][col].used));
    for (let i = 1; i < vals.length; i++) {
        if (!(vals[i] > vals[i - 1])) {
            fail(`${col} 不随折叠度上升：${vals.join(' / ')} —— 多半是解析串了行`);
        }
    }
}
for (const t of TIERS) {
    if (Number(nc[t].dsp.used) !== PE_NUM[t]) {
        fail(`${t} 的 DSP = ${nc[t].dsp.used}，应严格等于蝶形数 ${PE_NUM[t]}`);
    }
    if (Number(nc[t].iob.used) !== 37) {
        fail(`${t} 的 Bonded IOB = ${nc[t].iob.used}，参数化版应是常数 37（判据 1）`);
    }
    if (nc[t].state !== 'Routed') {
        fail(`${t} 的 Design State = 「${nc[t].state}」，参数化版三档都应布完线`);
    }
    /* 约束故意给紧（200 MHz），所以 WNS 必须为负。要是解析出正数，
     * 十有八九是扫到关键路径表里去了 —— 前面那条「跳过横线行」的坑。 */
    if (!(Number(nc[t].wns) < 0)) {
        fail(`${t} 的 WNS = ${nc[t].wns} ns，约束给的是 200 MHz，应为负 —— 多半解析串了行`);
    }
    if (nc[t].period !== '5.000') {
        fail(`${t} 的时钟周期 = ${nc[t].period} ns，不是脚本假定的 5.000`);
    }
}

/* ---- 人工记录的、报告里没有的数字 ------------------------------------- */
/* 三档周期数：rtl/probes/README.md §「判据 2」表（顶层实测 done 拍 − start − 3）。 */
const CYCLES = {
    pe1:  { fntt: 904, pwm2: 647, intt: 904 },
    pe4:  { fntt: 232, pwm2: 167, intt: 233 },
    pe16: { fntt: 69,  pwm2: 47,  intt: 71 }
};
/* 上游三档周期数：rtl/H1_port_spec.md §五。用来核对参数化版没改坏周期。 */
const CYCLES_UP = { pe1: 904, pe4: 232, pe16: 69 };
for (const t of TIERS) {
    if (CYCLES[t].fntt !== CYCLES_UP[t]) {
        fail(`${t} 的 FNTT 周期数 ${CYCLES[t].fntt} 与上游 ${CYCLES_UP[t]} 不一致（判据 2 要求逐档对齐）`);
    }
}

/* Vivado 报告里的 DDR / FF 总量，用来算占用率的稳定性 */
const LUT_TOTAL = Number(nc.pe1.lut.total);
const DEVICE_NOTE = 'xc7z020clg400-2（板上器件），53,200 LUT / 106,400 FF / 220 DSP / ' +
                    '140 BRAM tile / 280 RAMB18 / 125 IOB';

/* ---- 生成 markdown 表 -------------------------------------------------- */
const h = (s) => '`' + s + '`';

function mainTable(label, rows) {
    const lines = [
        `| 版本 | 档 | LUT | LUT% | FF | DSP | BRAM tile | RAMB18 | **IOB** | IOB% | WNS | 推算 Fmax | NTT 周期 | 实现状态 |`,
        `|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|`
    ];
    for (const t of TIERS) {
        const r = rows[t];
        lines.push(`| ${label} | ${t.replace('pe', '')} 蝶形 | ${r.lut.used} | ${r.lut.pct}% | ` +
                   `${r.ff.used} | ${r.dsp.used} | ${r.bramTile.used} | ${r.ramb18.used} | ` +
                   `**${r.iob.used}** | ${r.iob.pct}% | ${r.wns} ns | **${r.fmax} MHz** | ` +
                   `${CYCLES[t].fntt} | ${r.state} |`);
    }
    return lines.join('\n');
}

const GEN = [];
GEN.push('<!-- 这一段由 `node metrics/gen_metrics.mjs` 生成，别手改 -->', '');

GEN.push('### 主表：参数化版三档（`rtl/ntt_core/`，顶层边界）', '',
    mainTable('参数化', nc), '',
    '### 对照：上游三档顶层（同器件、同周期约束、同边界）', '',
    mainTable('上游', utop), '',
    `> 两表都是**顶层对顶层**（\`KyberHPMNTT_top\` vs \`KyberHPMNPE_top\`），边界一致才谈得上比。`,
    `> 上游 pe16 的 \`place_design\` 在 IO 阶段就失败，它的 LUT/FF 是综合后的值、WNS 是综合后估值，`,
    `> 与参数化版的布线后实测**不是同一个阶段**，不可直接比。`, '');

/* §8.3 的六项（+IOB），按模板的列走 */
const c = (vals) => vals.join(' ｜ ');
GEN.push('### 指标汇总表（按《选题指南》§3.2.5.2 的七列）', '',
    '| 指标名称 | 类别 | 数值（pe1 ｜ pe4 ｜ pe16） | 单位 | 测量条件 | 测试次数 / 时长 | 证据文件 |',
    '|---|---|---|---|---|---|---|',
    `| NTT 内核吞吐（周期数） | 核心 | ${c(TIERS.map((t) => CYCLES[t].fntt))} | cycles | ` +
        `一次 NTT 全程（7 层）；顶层量 \`done\` 拍 − \`start\` − 3；**不含读出延迟**；与上游逐档相同 | ` +
        `1 次探针实测；功能对拍另覆盖 16 组 × 3 档 | ` +
        `${h('rtl/probes/README.md')} §判据 2、${h('rtl/H1_port_spec.md')} §五 |`,
    `| 端到端延迟 | 核心 | 0.18–0.27 | s | 上板事务**墙钟**耗时（含 115200 bps 串口往返）；` +
        `2026-10-04 三档各 5 条事务；2026-10-15 pe1 复跑 5/6（\`#PMUL TIME\` 待新证据） | ` +
        `3 档 × 5 条各 1 次；单次 0.18–0.27 s | ` +
        `${h('rtl/vivado/run_board_txn_report.sh')}；${h('rtl/vivado/reports/board_pe1_txn.txt')} |`,
    `| KAT 通过率 | 核心 | 1000 / 1000 = **100** | % | 社区维护的 FIPS 203 兼容 \`.rsp\`（ML-KEM-768），` +
        `kat_verify.c 四项独立复算、逐比特（**不是 NIST 官方 KAT**，见 \`report/design/04_functional_correctness.md\` §4.4） | ` +
        `1000 条（逐比特） | ${h('research/mlkem_kat/')} |`,
    `| LUT 占用 | 资源 | ${c(TIERS.map((t) => nc[t].lut.used))} | 个 | post-route；` +
        `顶层边界；占用率 ${c(TIERS.map((t) => nc[t].lut.pct + '%'))} | ` +
        `1 份 post-route 报告（单次布线路程） | ` +
        `${TIERS.map((t) => h(`rtl/vivado/reports/${t}_nc_util.rpt`)).join('、')} |`,
    `| DSP 占用 | 资源 | ${c(TIERS.map((t) => nc[t].dsp.used))} | 个 | post-route；` +
        `**严格等于蝶形数**（非退化佐证） | 1 份 post-route 报告（单次布线路程） | 同上 |`,
    `| 最高频率 / WNS | 资源 | ${c(TIERS.map((t) => nc[t].fmax + ' MHz'))} | MHz | ` +
        `post-route；约束 \`create_clock -period 5\`（200 MHz，故意给紧），` +
        `Fmax = 1000 / (5 − WNS)；WNS ${c(TIERS.map((t) => nc[t].wns + ' ns'))} | ` +
        `1 份 post-route 报告（单次布线路程） | ` +
        `${TIERS.map((t) => h(`rtl/vivado/reports/${t}_nc_timing.rpt`)).join('、')} |`,
    `| IOB 占用 | 资源 | ${c(TIERS.map((t) => nc[t].iob.used))} | 个 | post-route；` +
        `**三档都是常数 37**（12 控制 + 1 时钟 + 12 \`din\` + 12 \`dout\`），与折叠度无关 —— 这是判据 1；` +
        `占用率 ${c(TIERS.map((t) => nc[t].iob.pct + '%'))}，上游同边界是 37 / 109 / **397** | ` +
        `1 份 post-route 报告（单次布线路程） | ${h('rtl/vivado/folding_comparison.md')} §9.2 |`, '');

GEN.push('### 功能正确性（B 侧验证台 + A 侧探针）', '',
    '| 验的是什么 | 判定 | 怎么判的 | 证据文件 |',
    '|---|---|---|---|',
    '| FIPS 203 兼容 KAT | 1000 / 1000 | 社区维护的 `.rsp`，四项独立复算 | `research/mlkem_kat/` |',
    '| 正变换 FNTT（上游 pe1） | 4096 / 4096 | RTL 落盘输出 vs 黄金向量，逐值 | `refsim/batch/fntt_rtl_out.txt` |',
    '| 逆变换 INTT（上游 pe1） | 4096 / 4096 | 16 组独立向量 | `refsim/README.md` §三 |',
    '| 点乘 PWM2（上游 pe1） | 4096 / 4096 | 16 组独立向量 | `refsim/README.md` §三 |',
    '| 往返自检 | 4096 / 4096 | RTL 的 FNTT 输出 → RTL 的 INTT → 时域原值（不经过 C 参考实现） | `refsim/README.md` §三 |',
    '| 完整乘法 FULL / 半程 HALF | 16 / 16 组 | 端到端，无缩放因子，逐比特 | `refsim/README.md` §三 |',
    `| 参数化版三档 × 三运算 | 9 / 9 组各 4096 / 4096 | 逐组比**多重集**（读出顺序随 (运算,档位) 变，不能按位置比） | ${h('rtl/probes/README.md')} §判据 3 |`,
    '', '> ⚠️ 「多重集相等」**弱于**「逐位置相等」：它只说明 256 个值都对，不保证顺序。',
    '> 上游 pe1 两侧都有锚（定位比 + 多重集），参数化版的读出顺序另行在 `rtl/H1_port_spec.md` 里定。', '');

/* ---- 写 CSV（长表，一行一个数） --------------------------------------- */
/* 《选题指南》§3.2.5.2 的七列表头：
   指标名称 ｜ 类别 ｜ 数值 ｜ 单位 ｜ 测量条件 ｜ 测试次数 / 时长 ｜ 证据文件
   「档位」不是独立列，并进「测量条件」；「测试次数 / 时长」逐行写实测口径。 */
const csvRows = [['指标名称', '类别', '数值', '单位', '测量条件', '测试次数 / 时长', '证据文件']];
const COND = {
    lut: 'post-route，顶层边界，Vivado ML Standard 2020.2 非工程模式，综合选项默认',
    ff: 'post-route，顶层边界，同上',
    dsp: 'post-route，顶层边界，同上',
    bramTile: 'post-route，顶层边界，同上',
    ramb18: 'post-route，顶层边界，同上（RAMB18 个数比 tile 直观）',
    iob: 'post-route，顶层边界，同上',
    fmax: 'post-route；Fmax = 1000 / (5 − WNS)，约束 create_clock -period 5',
    wns: 'post-route',
    cycles: '顶层实测 done 拍 − start − 3，不含读出延迟'
};
const TEST = {
    resource: '1 份 post-route 报告（单次布线路程）',
    cycles: '1 次探针实测；功能对拍另覆盖 16 组 × 3 档',
    e2e: '3 档 × 5 条各 1 次；单次 0.18–0.27 s',
    kat: '1000 条（逐比特）'
};
for (const t of TIERS) {
    const r = nc[t];
    const ev = `rtl/vivado/reports/${r.reportTag}_util.rpt`;
    const tev = `rtl/vivado/reports/${r.reportTag}_timing.rpt`;
    const cond = (s) => `档位 ${t}；${s}`;
    csvRows.push(['LUT', '资源', r.lut.used, '个', cond(COND.lut), TEST.resource, ev]);
    csvRows.push(['LUT 占用率', '资源', r.lut.pct, '%', cond(COND.lut), TEST.resource, ev]);
    csvRows.push(['FF', '资源', r.ff.used, '个', cond(COND.ff), TEST.resource, ev]);
    csvRows.push(['DSP', '资源', r.dsp.used, '个', cond(COND.dsp), TEST.resource, ev]);
    csvRows.push(['DSP 占用率', '资源', r.dsp.pct, '%', cond(COND.dsp), TEST.resource, ev]);
    csvRows.push(['BRAM tile', '资源', r.bramTile.used, 'tile', cond(COND.bramTile), TEST.resource, ev]);
    csvRows.push(['RAMB18', '资源', r.ramb18.used, '个', cond(COND.ramb18), TEST.resource, ev]);
    csvRows.push(['RAMB36', '资源', r.ramb36.used, '个', cond(COND.ramb18), TEST.resource, ev]);
    csvRows.push(['IOB', '资源', r.iob.used, '个', cond(COND.iob), TEST.resource, ev]);
    csvRows.push(['IOB 占用率', '资源', r.iob.pct, '%', cond(COND.iob), TEST.resource, ev]);
    csvRows.push(['WNS', '资源', r.wns, 'ns', cond(COND.wns), TEST.resource, tev]);
    csvRows.push(['WHS', '资源', r.whs, 'ns', cond(COND.wns), TEST.resource, tev]);
    csvRows.push(['推算 Fmax', '资源', r.fmax, 'MHz', cond(COND.fmax), TEST.resource, tev]);
    csvRows.push(['NTT 周期数', '核心', CYCLES[t].fntt, 'cycles', cond(COND.cycles), TEST.cycles, 'rtl/probes/README.md']);
    csvRows.push(['端到端延迟', '核心', '0.18-0.27', 's',
        cond('上板事务墙钟耗时（含串口往返）；2026-10-04 三档各 5 条；2026-10-15 pe1 复跑 5/6（#PMUL TIME 待新证据）'),
        TEST.e2e, 'rtl/vivado/run_board_txn_report.sh；rtl/vivado/reports/board_pe1_txn.txt']);
}
csvRows.push(['KAT 通过率', '核心', '1000/1000', '%', '三档通用；社区维护的 FIPS 203 兼容 .rsp', TEST.kat, 'research/mlkem_kat/']);

const csv = csvRows.map((r) => r.join(',')).join('\n') + '\n';

/* ---- 写产物 ----------------------------------------------------------- */
if (!ok) {
    console.error('\n❌ 自检未通过，不写产物。');
    process.exit(1);
}

const dataDir = path.join(HERE, 'data');
fs.mkdirSync(dataDir, { recursive: true });
const csvFile = path.join(dataDir, 'metrics.csv');
fs.writeFileSync(csvFile, csv, { encoding: 'utf8' });

/* 更新 README 的 GEN 块 */
const README = path.join(HERE, 'README.md');
const B = '<!-- GEN:BEGIN -->';
const E = '<!-- GEN:END -->';
let md = fs.readFileSync(README, 'utf8');
const i = md.indexOf(B), j = md.indexOf(E);
if (i < 0 || j < 0 || j < i) {
    console.error(`❌ metrics/README.md 里找不到 ${B} … ${E} 标记`);
    process.exit(1);
}
md = md.slice(0, i + B.length) + '\n\n' + GEN.join('\n') + '\n' + md.slice(j);
const norm = md.replace(/\r\n/g, '\n');
fs.writeFileSync(README, norm, { encoding: 'utf8' });

console.log('  指标表自检：');
console.log(`    三档 LUT  ${TIERS.map((t) => nc[t].lut.used).join(' / ')}` +
            `（随折叠度单调上升 ✅）`);
console.log(`    三档 DSP  ${TIERS.map((t) => nc[t].dsp.used).join(' / ')}（= 蝶形数 ✅）`);
console.log(`    三档 IOB  ${TIERS.map((t) => nc[t].iob.used).join(' / ')}（判据 1：常数 ✅）`);
console.log(`    三档 Fmax ${TIERS.map((t) => nc[t].fmax).join(' / ')} MHz` +
            `，WNS ${TIERS.map((t) => nc[t].wns).join(' / ')} ns`);
console.log(`    实现状态  ${TIERS.map((t) => nc[t].state).join(' / ')}`);
console.log(`    周期数    ${TIERS.map((t) => CYCLES[t].fntt).join(' / ')}` +
            `（与上游逐档相同 ✅）`);
console.log(`  ✅ 写出 ${path.relative(REPO, csvFile)}（${csvRows.length - 1} 行）`);
console.log(`  ✅ 更新 ${path.relative(REPO, README)} 的 GEN 块`);
