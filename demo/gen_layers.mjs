/* ===========================================================================
 * gen_layers.mjs —— 生成演示页要的「7 层中间结果」
 *
 * 用途：演示页要按一下走一层、看到数字在变。协议里**没有**「按层导出」这一条
 *       （会动到已冻结的帧格式，见 team/FPGA竞赛_C_引导与计划.md §四末尾口径 1），
 *       所以中间数据由 C 自己算 —— 这个脚本就是那个「自己算」。
 *
 * 算法来源（**只读引用，不改**）：refsim/ntt_layers.c 的 my_ntt()，即 ref/ntt.c
 *       ntt() 的逐行等价实现：CT/DIT 蝶形，len 从 128 递减到 2，k 从 1 递增，
 *       正逆共用同一张 zetas[]。zeta 表抄自 research/kyber_ref/ntt.c。
 *
 * 数值口径：每层都做 canonical 归一化（mod q，落回 0..3328）。
 *       这与 refsim/ntt_ref_tool.c 的输出口径一致（poly_ntt 后 to_canon 再打印），
 *       所以**第 7 层的结果应当逐值等于 research/mlkem_kat/ntt_out.hex** ——
 *       脚本把这个当自检判据，不通过就非零退出。
 *
 * 为什么用 Node 而不是 Python：A 的口径写的是「用 Python 生成」，但 C 这台机器
 *       没装 Python（09/29 自查，PATH 里只有 WindowsApps 占位符），已有 Node v24。
 *       算法与口径不变，只是换了宿主语言 —— 这件事记在 report/ai-log/ 里。
 *
 * 用法：node demo/gen_layers.mjs
 * 产物：demo/data/vectors.json（LF 行尾，无 BOM）
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

/* ---- 16 位语义：C 里 int16_t 的赋值会截断，这里显式复现 ---------------- */
const i16 = (x) => (x << 16) >> 16;

/* ---- ref/reduce.c: montgomery_reduce --------------------------------- */
function montgomeryReduce(a) {
    let t = i16(i16(a) * QINV);
    t = i16((a - t * Q) >> 16);
    return t;
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

/* ---- 逐层跑，同时留下每层快照与每层的 zeta 使用情况 ------------------- */
function runLayers(input) {
    const r = Int32Array.from(input, (v) => i16(v & 0x0fff));

    const snapshots = [Array.from(r, canon)];
    const layerMeta = [];        // 每层：len、组数、这层吃掉的 zeta 下标与取值

    let k = 1;
    for (let len = 128; len >= 2; len >>= 1) {
        const kFirst = k;
        let groups = 0;
        const zetaInLayer = [];

        for (let start = 0; start < N; start += 2 * len) {
            const zeta = ZETAS[k++];
            zetaInLayer.push(zeta);
            groups++;
            for (let j = start; j < start + len; j++) {
                const t = fqmul(zeta, r[j + len]);
                r[j + len] = i16(r[j] - t);
                r[j] = i16(r[j] + t);
            }
        }

        layerMeta.push({
            len,
            groups,
            zetaIndexFrom: kFirst,
            zetaIndexTo: k - 1,
            zetas: zetaInLayer
        });
        snapshots.push(Array.from(r, canon));
    }

    return { snapshots, layerMeta };
}

/* ---- 读黄金向量 ------------------------------------------------------- */
const rd = (p) =>
    fs.readFileSync(p, 'utf8').split('\n').map((s) => s.trim()).filter((s) => s !== '');

const hexToVal = (h) => parseInt(h, 16) & 0x0fff;

const rawIn = rd(path.join(KAT, 'ntt_in.hex'));
const rawOut = rd(path.join(KAT, 'ntt_out.hex'));
const NV = rawIn.length / N;

if (!Number.isInteger(NV) || rawOut.length !== rawIn.length) {
    console.error(`❌ 向量文件长度不对：in=${rawIn.length} out=${rawOut.length}`);
    process.exit(1);
}

/* ---- 逐组生成 + 自检 -------------------------------------------------- */
const vectors = [];
let allOk = true;

for (let v = 0; v < NV; v++) {
    const input = rawIn.slice(v * N, (v + 1) * N).map(hexToVal);
    const expected = rawOut.slice(v * N, (v + 1) * N).map(hexToVal);

    const { snapshots, layerMeta } = runLayers(input);

    const got = snapshots[snapshots.length - 1];
    const bad = [];
    for (let i = 0; i < N; i++) if (got[i] !== expected[i]) bad.push(i);

    if (bad.length) {
        allOk = false;
        console.error(`❌ 向量 ${v}：第 7 层与 ntt_out.hex 有 ${bad.length} 处不符，` +
                      `首处下标 ${bad[0]}（得 ${got[bad[0]]}，期望 ${expected[bad[0]]}）`);
    }

    vectors.push({
        id: v,
        input,
        layers: snapshots,        // 8 个快照：layers[0]=输入，layers[7]=变换结果
        expected,
        match: bad.length === 0
    });

    if (v === 0) {
        // 只打印第一组的层结构，够看清层序规则
        console.log(`  组 0 的层序（zeta 下标来自 zetas[]，正变换递增）：`);
        layerMeta.forEach((m, i) => {
            console.log(`    第 ${i + 1} 层  len=${String(m.len).padStart(3)}  ` +
                        `组数=${String(m.groups).padStart(2)}  ` +
                        `zetas[${m.zetaIndexFrom}]→[${m.zetaIndexTo}]  ` +
                        `首个 zeta=${m.zetas[0]}`);
        });
    }
}

console.log(`\n  对齐自检：${NV} 组向量的第 7 层 vs research/mlkem_kat/ntt_out.hex`);

/* 非退化检查（项目约定 3）：输入里有多少个不同值 */
const distinct = new Set(vectors.flatMap((v) => v.input)).size;
console.log(`  非退化检查：输入 ${vectors.length * N} 个系数里 ${distinct} 个不同值`);

if (!allOk) {
    console.error('\n❌ 自检未通过，不写产物。');
    process.exit(1);
}
console.log(`  ✅ ${NV}/${NV} 组全部逐值一致`);

/* ---- 写产物 ----------------------------------------------------------- */
const outDir = path.join(HERE, 'data');
fs.mkdirSync(outDir, { recursive: true });

const payload = {
    meta: {
        n: N,
        q: Q,
        nLayers: 7,
        nVectors: NV,
        valueFormat: 'canonical mod q，落回 0..3328；显示时另给 3 位小写十六进制',
        layerOrderSource: 'refsim/ntt_layers.c 的 my_ntt()（= ref/ntt.c ntt()，CT/DIT）',
        zetaSource: 'research/kyber_ref/ntt.c 的 zetas[128]',
        groundTruth: 'research/mlkem_kat/ntt_in.hex + ntt_out.hex',
        verified: `第 7 层与 ntt_out.hex 逐值一致（${NV}/${NV} 组）`,
        generator: 'demo/gen_layers.mjs（node）'
    },
    zetas: ZETAS,
    layerLen: [128, 64, 32, 16, 8, 4, 2],
    vectors
};

/* 写成 .js 而不是 .json：演示页要能**双击直接打开**，而 file:// 下
 * fetch() 本地 JSON 会被 CORS 拦掉。<script src> 不受此限，所以把数据
 * 挂成一个全局变量 —— 这样页面既能双击打开，也能放到 http 服务下跑。 */
const outFile = path.join(outDir, 'vectors.js');
const body = 'window.NTT_DATA = ' + JSON.stringify(payload) + ';\n';
fs.writeFileSync(outFile, body, { encoding: 'utf8' });

const kb = (fs.statSync(outFile).size / 1024).toFixed(1);
console.log(`  ✅ 写出 ${path.relative(REPO, outFile)}（${kb} KB，LF 行尾）`);
