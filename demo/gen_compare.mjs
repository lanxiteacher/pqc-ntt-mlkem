/* ===========================================================================
 * gen_compare.mjs —— 生成对拍页要的数据
 *
 * 「对拍」= 把 RTL 仿真真正落盘出来的输出，跟黄金向量逐值比。
 *
 * 两件要紧的事：
 *
 * ① **只有 FNTT 有 RTL 落盘文件。** 仓库里 `*rtl_out*` 搜下来只有一个
 *    `refsim/batch/fntt_rtl_out.txt`（由 `fntt_batch_tb_dump.v +dump=1` 写出）。
 *    其余运算（INTT / PWM2 / FULL / HALF / 往返）的判定是 testbench **内部**
 *    打印的 pass/fail 统计，没有逐数值落盘 —— 所以那些数字只能**引用**
 *    `refsim/README.md` §三 的记录，并在页面上标清楚「引用，不是本页复算」。
 *    这里不替它们编造逐值数据。
 *
 * ② 凡是能在仓库数据里复算的，一律复算，并且跟 README 的表**逐格核对**，
 *    对不上就非零退出。这样页面上的数字要么是本脚本算出来的，要么是明确
 *    标注了出处的引用 —— 没有第三种。
 *
 * 用法：node demo/gen_compare.mjs
 * 产物：demo/data/compare.js
 * =========================================================================== */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const KAT = path.join(REPO, 'research', 'mlkem_kat');
const BATCH = path.join(REPO, 'refsim', 'batch');

const N = 256;

const rd = (p) =>
    fs.readFileSync(p, 'utf8').split('\n').map((s) => s.trim()).filter((s) => s !== '');

let ok = true;
const fail = (msg) => { ok = false; console.error('❌ ' + msg); };

/* ---- ① FNTT：RTL 落盘输出 vs 黄金向量 ---------------------------------- */
const rtl = rd(path.join(BATCH, 'fntt_rtl_out.txt'));
const golden = rd(path.join(KAT, 'ntt_out.hex'));

if (rtl.length !== golden.length) {
    fail(`列数不齐：fntt_rtl_out=${rtl.length} ntt_out.hex=${golden.length}`);
}
const NV = golden.length / N;
if (!Number.isInteger(NV)) fail(`ntt_out.hex 行数 ${golden.length} 不是 256 的整数倍`);

const perVector = [];
let totalMatch = 0;
for (let v = 0; v < NV; v++) {
    let m = 0;
    for (let i = 0; i < N; i++) if (rtl[v * N + i] === golden[v * N + i]) m++;
    perVector.push({ id: v, match: m, of: N });
    totalMatch += m;
}
if (totalMatch !== golden.length) {
    const first = (() => {
        for (let i = 0; i < golden.length; i++) if (rtl[i] !== golden[i]) return i;
        return -1;
    })();
    fail(`FNTT 对拍不是全中：${totalMatch}/${golden.length}，首处不符在 ${first}`);
}

/* ---- ② 非退化统计：从 batch 文件复算，再跟 README §三 的表逐格核对 ----- */
/* 期望值是从 refsim/README.md §三 的表里**抄下来当断言**的 —— 抄错就会在这里炸。 */
const EXPECT = [
    ['intt_batch_in',  4096, 2374, '0.15'],
    ['intt_batch_exp', 4096, 2355, '0.17'],
    ['pwm2_batch_a',   4096, 2374, '0.15'],
    ['pwm2_batch_exp', 4096, 2371, '0.22'],
    ['fullmul_a',      4096, 2355, '0.17'],
    ['fullmul_b',      4096, 2355, '0.17'],
    ['fullmul_exp',    4096, 2357, '0.20'],
    ['halfmul_b',      4096, 2374, '0.15'],
    ['halfmul_exp',    4096, 2357, '0.20']
];

const nondegen = [];
for (const [name, rows, distinct, topPct] of EXPECT) {
    const L = rd(path.join(BATCH, name + '.txt'));
    const m = new Map();
    for (const x of L) m.set(x, (m.get(x) || 0) + 1);
    let top = 0;
    for (const c of m.values()) if (c > top) top = c;
    const gotPct = (100 * top / L.length).toFixed(2);

    if (L.length !== rows) fail(`${name}：行数 ${L.length}，README 记的是 ${rows}`);
    if (m.size !== distinct) fail(`${name}：不同值 ${m.size}，README 记的是 ${distinct}`);
    if (gotPct !== topPct) fail(`${name}：最常见占比 ${gotPct}%，README 记的是 ${topPct}%`);

    nondegen.push({ file: name + '.txt', rows: L.length, distinct: m.size, topPct: gotPct });
}

/* ---- ③ 阴性对照：README §三 记录的那一次 ------------------------------- */
/* 原文：把 fullmul_exp 第 7 组第 100 号系数改成 001，重跑 tb
 *        → `向量 7 [100]: 期望 001 得到 3d4` / `向量 7: ❌ 255/256` / `共 1 个系数不符`
 * 没装 iverilog 跑不了 tb，但能核一件事：fullmul_exp 那一位**原本**就是 3d4，
 * 与 README 说的「得到 3d4」自洽（RTL 本来是全中的）。 */
const fmExp = rd(path.join(BATCH, 'fullmul_exp.txt'));
const NEG_I = 7 * N + 100;
const negGot = fmExp[NEG_I];
if (negGot !== '3d4') fail(`阴性对照核对失败：fullmul_exp[${NEG_I}] = ${negGot}，README 说 RTL 报的是 3d4`);

const negCtrl = {
    op: '完整乘法 FULL',
    vector: 7,
    index: 100,
    linear: NEG_I,
    written: '001',
    rtlGot: negGot,
    match: N - 1,
    of: N,
    mismatches: 1,
    source: 'refsim/README.md §三「阴性对照」',
    crossCheck: `已核 fullmul_exp.txt 第 ${NEG_I} 行 = ${negGot}，与记录里「得到 3d4」自洽`
};

/* ---- ④ 同一份数据的几条不变量 ----------------------------------------- */
const nttOut = rd(path.join(KAT, 'ntt_out.hex'));
const inttIn = rd(path.join(KAT, 'intt_in.hex'));
let same = nttOut.length === inttIn.length;
if (same) for (let i = 0; i < nttOut.length; i++) if (nttOut[i] !== inttIn[i]) { same = false; break; }
if (!same) fail('intt_in.hex 与 ntt_out.hex 不是同一份数据（ntt_vectors.txt 第 14 行这么说）');

/* run_fntt_check.sh 会把 KAT 的向量拷成 batch/ 下的副本给 testbench 用，
 * 这里核一下副本没被改花（副本是 LF，KAT 原件是 CRLF —— 读进来都 trim）。 */
const nttIn = rd(path.join(KAT, 'ntt_in.hex'));
const batchIn = rd(path.join(BATCH, 'ntt_batch_in.txt'));
if (nttIn.length !== batchIn.length) {
    fail(`ntt_batch_in.txt 行数 ${batchIn.length}，ntt_in.hex 是 ${nttIn.length}`);
} else {
    for (let i = 0; i < nttIn.length; i++) {
        if (nttIn[i] !== batchIn[i]) { fail(`ntt_batch_in.txt 第 ${i} 行与 ntt_in.hex 不一致`); break; }
    }
}

/* ---- ⑤ 引用 B 的记录（没有逐值落盘，本页不复算） ---------------------- */
const quoted = [
    { op: 'KAT 向量集',        result: '1000 / 1000',
      how: 'kat_verify.c 四项独立复算（逐比特）',
      evidence: 'research/mlkem_kat/', recomputed: false },
    { op: '正变换 FNTT',       result: `${totalMatch} / ${golden.length}`,
      how: 'RTL 落盘输出 vs 黄金向量，逐值',
      evidence: 'refsim/batch/fntt_rtl_out.txt ↔ research/mlkem_kat/ntt_out.hex', recomputed: true },
    { op: '逆变换 INTT',       result: '4096 / 4096',
      how: '16 组独立向量，testbench 内部统计',
      evidence: 'refsim/README.md §三', recomputed: false },
    { op: '点乘 PWM2',         result: '4096 / 4096',
      how: '16 组独立向量，testbench 内部统计',
      evidence: 'refsim/README.md §三', recomputed: false },
    { op: '往返自检',          result: '4096 / 4096',
      how: 'RTL 的 FNTT 实际输出 → RTL 的 INTT → 时域原值（完全不经过 C 参考实现）',
      evidence: 'refsim/README.md §三', recomputed: false },
    { op: '完整乘法 FULL',     result: '16 / 16 组',
      how: 'FNTT→FNTT→PWM2→INTT 端到端，无缩放因子，逐比特',
      evidence: 'refsim/README.md §三', recomputed: false },
    { op: '半程乘法 HALF',     result: '16 / 16 组',
      how: 'FNTT→PWM2→INTT 端到端，无缩放因子，逐比特',
      evidence: 'refsim/README.md §三', recomputed: false }
];

const limits = [
    '验到「一次多项式乘法」为止，不是「一次 ML-KEM 运算」为止 —— 更外层的 polyvec 累加点乘、base case 乘法、poly_tomont/poly_reduce 归位尚未验。',
    '单运算那一层（INTT / PWM2）的期望值要按常数因子换算：RTL 的 INTT 输出 = poly_invntt_tomont × R⁻¹，PWM2 输出 = poly_basemul_montgomery × R（R = 2285，R⁻¹ = 169）。端到端那两组没有这个问题。',
    '只验了 PE_NUMBER = 1 的配置；多 PE 并行版本没验。',
    '只做了功能验证，没有验面积 / 时序 / 功耗。',
    '作者的 testbench 数据只对了 2 组，16 组主力向量是我方补的。'
];

/* ---- 汇总 ------------------------------------------------------------- */
console.log('  对拍页数据自检：');
console.log(`    FNTT RTL 落盘 vs 黄金向量：${totalMatch}/${golden.length}` +
            `（${perVector.filter((p) => p.match === p.of).length}/${NV} 组全中）`);
console.log(`    非退化统计：${nondegen.length} 个文件，全部与 README §三 的表逐格一致`);
console.log(`    阴性对照：fullmul_exp[${NEG_I}] = ${negGot}（README 记「得到 3d4」）`);
console.log(`    不变量：intt_in.hex == ntt_out.hex；ntt_batch_in.txt == ntt_in.hex`);

if (!ok) {
    console.error('\n❌ 自检未通过，不写产物。');
    process.exit(1);
}
console.log('  ✅ 全部通过');

/* ---- 写产物 ----------------------------------------------------------- */
const outDir = path.join(HERE, 'data');
fs.mkdirSync(outDir, { recursive: true });

const payload = {
    meta: {
        n: N,
        nVectors: NV,
        valueFormat: '每行恰好 3 位小写十六进制；比对按字符串逐行比（不做数值归一化）',
        rtlSource: 'refsim/batch/fntt_rtl_out.txt（fntt_batch_tb_dump.v +dump=1 写出，CRLF）',
        goldenSource: 'research/mlkem_kat/ntt_out.hex（CRLF）',
        caNote: '⚠️ 两个文件行尾都是 CRLF，读进来先 trim 再比；仓库约定 `* -text`，字节原样入库',
        generator: 'demo/gen_compare.mjs（node）'
    },
    fntt: {
        rtl,
        golden,
        perVector,
        totalMatch,
        total: golden.length,
        allVectorsFull: perVector.every((p) => p.match === p.of)
    },
    negCtrl,
    nondegen,
    nondegenSource: 'refsim/README.md §三「非退化统计」表（本页逐格复算核对）',
    quoted,
    limits,
    limitsSource: 'refsim/README.md §八「这条链没覆盖什么」'
};

const outFile = path.join(outDir, 'compare.js');
fs.writeFileSync(outFile, 'window.COMPARE_DATA = ' + JSON.stringify(payload) + ';\n',
                 { encoding: 'utf8' });

const kb = (fs.statSync(outFile).size / 1024).toFixed(1);
console.log(`  ✅ 写出 ${path.relative(REPO, outFile)}（${kb} KB，LF 行尾）`);
