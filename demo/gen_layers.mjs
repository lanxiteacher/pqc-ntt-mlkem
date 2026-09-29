/* ===========================================================================
 * gen_layers.mjs —— 生成演示页要的「逐层中间结果」
 *
 * 用途：演示页要按一下走一层、看到数字在变。协议里**没有**「按层导出」这一条
 *       （会动到已冻结的帧格式，见 team/FPGA竞赛_C_引导与计划.md §四末尾口径 1），
 *       所以中间数据由 C 自己算 —— 这个脚本就是那个「自己算」。
 *
 * 一次出两个方向（两页共用一份数据）：
 *       正变换  ntt_in.hex  → ntt_out.hex    CT/DIT 蝶形，len 128→2，k 从 1 递增
 *       逆变换  intt_in.hex → intt_out.hex   GS/DIF 蝶形，len 2→128，k 从 127 递减
 *                                          + 末级逐系数缩放 f = 1441
 *
 * 算法来源（**只读引用，不改**）：refsim/ntt_layers.c 的 my_ntt() / my_invntt()，
 *       即 ref/ntt.c ntt()/invntt() 的逐行等价实现；zeta 表抄自
 *       research/kyber_ref/ntt.c。正逆**共用同一张 zetas[]**，只是走的方向相反
 *       —— 仓库里从来不存在一张 zetas_inv。
 *
 * 数值口径：每层都做 canonical 归一化（mod q，落回 0..3328）。
 *       这与 refsim/ntt_ref_tool.c 的输出口径一致（poly_ntt / poly_invntt_tomont
 *       之后 to_canon 再打印），所以：
 *         正变换第 7 层 应当逐值等于 research/mlkem_kat/ntt_out.hex
 *         逆变换末级  应当逐值等于 research/mlkem_kat/intt_out.hex
 *       两条都当自检判据，任一条不过就非零退出、不写产物。
 *
 * 为什么用 Node 而不是 Python：A 的口径写的是「用 Python 生成」，但 C 这台机器
 *       没装 Python（09/29 自查，PATH 里只有 WindowsApps 占位符），已有 Node v24。
 *       算法与口径不变，只是换了宿主语言 —— 这件事记在 report/ai-log/ 里。
 *
 * 用法：node demo/gen_layers.mjs
 * 产物：demo/data/vectors.js
 * =========================================================================== */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const KAT = path.join(REPO, 'research', 'mlkem_kat');

const N = 256;
const Q = 3329;
const QINV = -3327;   // q^-1 mod 2^16
const MONT = -1044;   // 2^16 mod q（本脚本用不到，留着标注口径）
const F_INV = 1441;   // mont^2/128，逆变换末级缩放

/* ---- 16 位语义：C 里 int16_t 的赋值会截断，这里显式复现 ---------------- */
const i16 = (x) => (x << 16) >> 16;

/* ---- ref/reduce.c: montgomery_reduce --------------------------------- */
function montgomeryReduce(a) {
    let t = i16(i16(a) * QINV);
    t = i16((a - t * Q) >> 16);
    return t;
}

/* ---- ref/reduce.c: barrett_reduce —— 取中心代表（-(q-1)/2 .. (q-1)/2） */
function barrettReduce(a) {
    const v = 20159;            // ((1<<26) + q/2) / q，整数除法
    let t = i16((Math.imul(v, a) + (1 << 25)) >> 26);
    t = i16(t * Q);
    return i16(a - t);
}

/* ---- ref/ntt.c: fqmul = montgomery_reduce(a * b) ---------------------- */
function fqmul(a, b) {
    return montgomeryReduce(Math.imul(a, b));
}

/* ---- zetas[128]：抄自 research/kyber_ref/ntt.c ----------------------- */
const ZETAS = [
    -1044, -758, -359, -1517, 1493, 1422, 287, 202,
    -171, 622, 1577, 182, 962, -1202, -1474, 1468,
    573, -1325, 264, 383, -829, 1458, -1602, -130,
    -681, 1017, 732, 608, -1542, 411, -205, -1571,
    1223, 652, -552, 1015, -1293, 1491, -282, -1544,
    516, -8, -320, -666, -1618, -1162, 126, 1469,
    -853, -90, -271, 830, 107, -1421, -247, -951,
    -398, 961, -1508, -725, 448, -1065, 677, -1275,
    -1103, 430, 555, 843, -1251, 871, 1550, 105,
    422, 587, 177, -235, -291, -460, 1574, 1653,
    -246, 778, 1159, -147, -777, 1483, -602, 1119,
    -1590, 644, -872, 349, 418, 329, -156, -75,
    817, 1097, 603, 610, 1322, -1285, -1465, 384,
    -1215, -136, 1218, -1335, -874, 220, -1187, -1659,
    -1185, -1530, -1278, 794, -1510, -854, -870, 478,
    -108, -308, 996, 991, 958, -1460, 1522, 1628
];

const canon = (v) => ((v % Q) + Q) % Q;

/* ---- 正变换：CT/DIT，len 从 128 递减到 2，k 从 1 递增 ------------------ */
function runNttLayers(input) {
    const r = Int32Array.from(input, (v) => i16(v & 0x0fff));
    const snaps = [Array.from(r, canon)];
    const steps = [];

    let k = 1;
    for (let len = 128; len >= 2; len >>= 1) {
        const zetaFrom = k;
        let groups = 0;
        for (let start = 0; start < N; start += 2 * len) {
            const zeta = ZETAS[k++];
            groups++;
            for (let j = start; j < start + len; j++) {
                const t = fqmul(zeta, r[j + len]);
                r[j + len] = i16(r[j] - t);
                r[j] = i16(r[j] + t);
            }
        }
        steps.push({ kind: 'layer', len, groups, zetaFrom, zetaTo: k - 1 });
        snaps.push(Array.from(r, canon));
    }
    return { snaps, steps };
}

/* ---- 逆变换：GS/DIF，len 从 2 递增到 128，k 从 127 递减，末尾乘 f ---- */
function runInttLayers(input) {
    const r = Int32Array.from(input, (v) => i16(v & 0x0fff));
    const snaps = [Array.from(r, canon)];
    const steps = [];

    let k = 127;
    for (let len = 2; len <= 128; len <<= 1) {
        const zetaFrom = k;
        let groups = 0;
        for (let start = 0; start < N; start += 2 * len) {
            const zeta = ZETAS[k--];
            groups++;
            for (let j = start; j < start + len; j++) {
                const t = r[j];
                r[j] = barrettReduce(i16(t + r[j + len]));
                r[j + len] = i16(r[j + len] - t);
                r[j + len] = fqmul(zeta, r[j + len]);
            }
        }
        steps.push({ kind: 'layer', len, groups, zetaFrom, zetaTo: k + 1 });
        snaps.push(Array.from(r, canon));
    }

    for (let j = 0; j < N; j++) r[j] = fqmul(r[j], F_INV);
    steps.push({ kind: 'scale', f: F_INV });
    snaps.push(Array.from(r, canon));

    return { snaps, steps };
}

/* ---- 读黄金向量 ------------------------------------------------------- */
const rd = (p) =>
    fs.readFileSync(p, 'utf8').split('\n').map((s) => s.trim()).filter((s) => s !== '');

const hexToVal = (h) => parseInt(h, 16) & 0x0fff;

const rawNttIn = rd(path.join(KAT, 'ntt_in.hex'));
const rawNttOut = rd(path.join(KAT, 'ntt_out.hex'));
const rawInttIn = rd(path.join(KAT, 'intt_in.hex'));
const rawInttOut = rd(path.join(KAT, 'intt_out.hex'));
const NV = rawNttIn.length / N;

for (const [name, arr] of [['ntt_out', rawNttOut], ['intt_in', rawInttIn], ['intt_out', rawInttOut]]) {
    if (arr.length !== rawNttIn.length) {
        console.error(`❌ 向量文件长度不齐：ntt_in=${rawNttIn.length} ${name}=${arr.length}`);
        process.exit(1);
    }
}
if (!Number.isInteger(NV)) {
    console.error(`❌ ntt_in.hex 行数 ${rawNttIn.length} 不是 256 的整数倍`);
    process.exit(1);
}

/* ---- 逐组生成 + 双自检 ------------------------------------------------ */
const nttVecs = [];
const inttVecs = [];
let nttSteps = null, inttSteps = null;
let allOk = true;

function diffIndices(a, b) {
    const bad = [];
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) bad.push(i);
    return bad;
}

for (let v = 0; v < NV; v++) {
    const nttIn = rawNttIn.slice(v * N, (v + 1) * N).map(hexToVal);
    const nttExp = rawNttOut.slice(v * N, (v + 1) * N).map(hexToVal);
    const inttIn = rawInttIn.slice(v * N, (v + 1) * N).map(hexToVal);
    const inttExp = rawInttOut.slice(v * N, (v + 1) * N).map(hexToVal);

    /* ntt_vectors.txt 第 14 行：intt_in 就是 ntt_out。核一遍，别只信注释。 */
    const joinBad = diffIndices(inttIn, nttExp);
    if (joinBad.length) {
        allOk = false;
        console.error(`❌ 向量 ${v}：intt_in.hex 与 ntt_out.hex 不相等，${joinBad.length} 处` +
                      `（首处下标 ${joinBad[0]}）—— 两者本应是同一份数据`);
    }

    const A = runNttLayers(nttIn);
    const B = runInttLayers(inttIn);

    const gotA = A.snaps[A.snaps.length - 1];
    const gotB = B.snaps[B.snaps.length - 1];
    const badA = diffIndices(gotA, nttExp);
    const badB = diffIndices(gotB, inttExp);

    if (badA.length) {
        allOk = false;
        console.error(`❌ 正变换 向量 ${v}：第 7 层与 ntt_out.hex 有 ${badA.length} 处不符，` +
                      `首处下标 ${badA[0]}（得 ${gotA[badA[0]]}，期望 ${nttExp[badA[0]]}）`);
    }
    if (badB.length) {
        allOk = false;
        console.error(`❌ 逆变换 向量 ${v}：末级与 intt_out.hex 有 ${badB.length} 处不符，` +
                      `首处下标 ${badB[0]}（得 ${gotB[badB[0]]}，期望 ${inttExp[badB[0]]}）`);
    }

    nttVecs.push({ id: v, input: nttIn, snaps: A.snaps, expected: nttExp });
    inttVecs.push({ id: v, input: inttIn, snaps: B.snaps, expected: inttExp });

    if (v === 0) {
        nttSteps = A.steps;
        inttSteps = B.steps;
        console.log('  组 0 的层序（zeta 下标取自同一张 zetas[]，两个方向相反）：');
        A.steps.forEach((m, i) => console.log(
            `    正 第 ${i + 1} 层  len=${String(m.len).padStart(3)}  ` +
            `组数=${String(m.groups).padStart(2)}  zetas[${m.zetaFrom}]→[${m.zetaTo}]  ` +
            `首个 zeta=${ZETAS[m.zetaFrom]}`));
        B.steps.forEach((m, i) => console.log(
            m.kind === 'scale'
            ? `    逆 末级缩放  f = ${m.f}（逐系数乘一遍，不是蝶形）`
            : `    逆 第 ${i + 1} 步  len=${String(m.len).padStart(3)}  ` +
              `组数=${String(m.groups).padStart(2)}  zetas[${m.zetaFrom}]→[${m.zetaTo}]  ` +
              `首个 zeta=${ZETAS[m.zetaFrom]}`));
    }
}

console.log(`\n  双自检：${NV} 组向量`);
console.log(`    正变换第 7 层  vs ntt_out.hex   `);
console.log(`    逆变换末级     vs intt_out.hex  `);

/* 非退化检查（项目约定 3）：输入里有多少个不同值 */
const dNtt = new Set(nttVecs.flatMap((v) => v.input)).size;
const dIntt = new Set(inttVecs.flatMap((v) => v.input)).size;
console.log(`  非退化检查：正变换输入 ${dNtt} 个不同值；逆变换输入 ${dIntt} 个不同值` +
            `（各 ${NV * N} 个系数）`);

if (!allOk) {
    console.error('\n❌ 自检未通过，不写产物。');
    process.exit(1);
}
console.log(`  ✅ 正变换 ${NV}/${NV} 组逐值一致`);
console.log(`  ✅ 逆变换 ${NV}/${NV} 组逐值一致`);

/* ---- 写产物 ----------------------------------------------------------- */
const outDir = path.join(HERE, 'data');
fs.mkdirSync(outDir, { recursive: true });

const payload = {
    meta: {
        n: N,
        q: Q,
        nVectors: NV,
        valueFormat: 'canonical mod q，落回 0..3328；显示时另给 3 位小写十六进制',
        layerOrderSource: 'refsim/ntt_layers.c 的 my_ntt() / my_invntt()',
        zetaSource: 'research/kyber_ref/ntt.c 的 zetas[128]（正逆共用，无 zetas_inv）',
        groundTruth: 'research/mlkem_kat/ 的 ntt_in/ntt_out/intt_in/intt_out.hex',
        invariant: 'intt_in.hex 与 ntt_out.hex 是同一份数据（已逐值核对）',
        generator: 'demo/gen_layers.mjs（node）'
    },
    zetas: ZETAS,
    dirs: {
        ntt: {
            key: 'ntt',
            name: '正变换',
            abbr: 'NTT',
            butterfly: 'CT / DIT',
            zetaDir: 1,
            steps: nttSteps,
            vectors: nttVecs
        },
        intt: {
            key: 'intt',
            name: '逆变换',
            abbr: 'INTT',
            butterfly: 'GS / DIF',
            zetaDir: -1,
            steps: inttSteps,
            vectors: inttVecs
        }
    }
};

/* 写成 .js 而不是 .json：演示页要能**双击直接打开**，而 file:// 下
 * fetch() 本地 JSON 会被 CORS 拦掉。<script src> 不受此限，所以把数据
 * 挂成一个全局变量 —— 这样页面既能双击打开，也能放到 http 服务下跑。 */
const outFile = path.join(outDir, 'vectors.js');
const body = 'window.NTT_DATA = ' + JSON.stringify(payload) + ';\n';
fs.writeFileSync(outFile, body, { encoding: 'utf8' });

const kb = (fs.statSync(outFile).size / 1024).toFixed(1);
console.log(`  ✅ 写出 ${path.relative(REPO, outFile)}（${kb} KB，LF 行尾）`);
