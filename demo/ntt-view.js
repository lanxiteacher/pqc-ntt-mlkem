/* ===========================================================================
 * ntt-view.js —— 「按一下走一层」的可视化，正变换与逆变换共用这一份代码
 *
 * 两个方向的结构完全对称（见 gen_layers.mjs 打印的层序表）：
 *     正  len 128→2   组数 1→64    zetas[1]→[127] 递增
 *     逆  len 2→128   组数 64→1    zetas[127]→[1] 递减   + 末级逐系数缩放
 * 所以只有「每步显示什么」「蝶形算式怎么写」两处不同，其余共用。
 *
 * 用法（页面里）：
 *     <script src="data/vectors.js"></script>
 *     <script src="ntt-view.js"></script>
 *     <script>NttView.mount('ntt');</script>     // 或 'intt'
 *
 * ⚠️ 素因子：fqmul 是 **Montgomery 乘**，自带 R⁻¹ = 169 的因子；
 *    表里的 zeta 又是 Montgomery 域的值（zetas[0] = 2285 = R）。
 *    所以页面上**不能**把 t 写成普通的「zeta × b」—— 见 renderButterfly()。
 * =========================================================================== */

(function () {
  'use strict';

  /* ---- 与生成器一致的 16 位算术（只用来在页面上复算 t，供显示与自检） ---- */
  const Q = 3329;
  const QINV = -3327;
  const i16 = (x) => (x << 16) >> 16;
  function montgomeryReduce(a) {
    let t = i16(i16(a) * QINV);
    t = i16((a - t * Q) >> 16);
    return t;
  }
  const fqmul = (a, b) => montgomeryReduce(Math.imul(a, b));
  const canon = (v) => ((v % Q) + Q) % Q;

  const hex3 = (v) => v.toString(16).padStart(3, '0');

  /* 每个方向的蝶形算式（写成字符串，直接显示给读者） */
  const FORMULA = {
    ntt: {
      big: 't = fqmul(zeta, b)<br>a′ = a + t　　b′ = a − t',
      note: 'CT / DIT 蝶形。两个输出都只用<b>变换前</b>的 a —— t 先算好，a′ 与 b′ 再各取一次。'
    },
    intt: {
      big: 't = a<br>a′ = a + b　　b′ = fqmul(zeta, b − t)',
      note: 'GS / DIF 蝶形。a′ 只用一次 barrett_reduce 把代表拉回中心附近（数值 mod q 不变）；' +
            'b′ 里的 t 是<b>变换前</b>的 a。'
    }
  };

  const NAV = [
    { key: 'ntt',     href: 'index.html',   label: '正变换 NTT' },
    { key: 'intt',    href: 'intt.html',    label: '逆变换 INTT' },
    { key: 'compare', href: 'compare.html', label: '对拍结果' }
  ];

  /* 颜色全部走变量 —— 深色是默认，浅色（?theme=light）只覆盖变量，
     所以「两份主题」是同一套布局，不会各写各的。见 css() 里的 themeAttr()。 */
  const CSS = `
    :root {
      --bg:#12151a; --panel:#1a1f27; --line:#2c333e;
      --fg:#d8dee9; --dim:#7c8998; --accent:#4c9aff;
      --hot:#b8791f; --hot-bg:#3a2c12; --sel:#2d4a75; --ok:#5f9e5f;
      --code:#f0c674; --chg-fg:#f0c674; --sel-fg:#ffffff; --pair-fg:#9dc4f5;
      --btn-bg:#232a34;
      --ok-fg:#9ed49e; --err-fg:#ff9d9d;
      --bad-bg:#5a1f1f; --bad-fg:#ffd0d0; --bad-line:#cc4444;
    }
    :root[data-theme="light"] {
      --bg:#ffffff; --panel:#f6f8fa; --line:#d0d7de;
      --fg:#1c1f24; --dim:#57616e; --accent:#1d63c9;
      --hot:#9a5a12; --hot-bg:#fbe8c6; --sel:#cfe1ff; --ok:#2f7a2f;
      --code:#9a5200; --chg-fg:#6f4200; --sel-fg:#08234a; --pair-fg:#1d63c9;
      --btn-bg:#e9edf2;
      --ok-fg:#1f7a1f; --err-fg:#b0231f;
      --bad-bg:#ffd9d9; --bad-fg:#8a1f1f; --bad-line:#cc3333;
    }
    * { box-sizing:border-box; }
    html { background:var(--bg); }
    body { margin:0; background:var(--bg); color:var(--fg);
           font:14px/1.6 "Consolas","Cascadia Mono","Courier New",monospace; }
    header { padding:14px 20px; border-bottom:1px solid var(--line); }
    h1 { margin:0 0 4px; font-size:17px; font-weight:600; }
    .sub { color:var(--dim); font-size:12px; }
    nav { padding:0 20px; border-bottom:1px solid var(--line); display:flex; gap:2px; }
    nav a { color:var(--dim); text-decoration:none; padding:8px 14px; font-size:13px;
            border-bottom:2px solid transparent; }
    nav a:hover { color:var(--fg); }
    nav a.on { color:var(--accent); border-bottom-color:var(--accent); }
    main { display:flex; gap:18px; padding:18px 20px; align-items:flex-start; flex-wrap:wrap; }
    .grid { display:grid; grid-template-columns:repeat(16,46px); gap:2px; }
    .cell { height:26px; display:flex; align-items:center; justify-content:center;
            background:var(--panel); border:1px solid transparent; border-radius:3px;
            font-size:12px; color:var(--dim); cursor:pointer; user-select:none; }
    .cell.on  { color:var(--fg); }
    .cell.chg { background:var(--hot-bg); color:var(--chg-fg); border-color:var(--hot); }
    .cell.sel { background:var(--sel); color:var(--sel-fg); border-color:var(--accent); }
    .cell.pair { outline:1px dashed var(--accent); outline-offset:-1px; color:var(--pair-fg); }
    .panel { flex:1 1 340px; min-width:320px; max-width:460px; }
    .box { background:var(--panel); border:1px solid var(--line); border-radius:6px;
           padding:12px 14px; margin-bottom:12px; }
    .box h2 { margin:0 0 8px; font-size:13px; color:var(--accent); font-weight:600; }
    .kv { display:grid; grid-template-columns:auto 1fr; gap:2px 12px; font-size:13px; }
    .kv dt { color:var(--dim); }
    .kv dd { margin:0; }
    code { color:var(--code); }
    .bar { display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin-bottom:12px; }
    button, select { background:var(--btn-bg); color:var(--fg); border:1px solid var(--line);
                     border-radius:4px; padding:6px 12px; font:inherit; font-size:13px; cursor:pointer; }
    button:hover { border-color:var(--accent); }
    button:disabled { opacity:.35; cursor:default; border-color:var(--line); }
    .stage { font-size:13px; color:var(--dim); }
    .stage b { color:var(--fg); font-size:15px; }
    .legend { font-size:12px; color:var(--dim); }
    .legend b { color:var(--fg); font-weight:600; }
    .swatch { display:inline-block; width:10px; height:10px; border-radius:2px; vertical-align:-1px; }
    table.bf { width:100%; border-collapse:collapse; font-size:12px; }
    table.bf th, table.bf td { text-align:left; padding:2px 6px 2px 0; color:var(--dim);
                               vertical-align:top; }
    table.bf td.v { color:var(--fg); }
    .ok { color:var(--ok); }
    footer { color:var(--dim); font-size:12px; padding:4px 20px 24px; }
  `;

  /* 主题：?theme=light 切浅底（报告要黑白可读），默认深底。
     三个页面都调 css()，所以主题由这里统一决定，各页不必各写一遍。 */
  function theme() {
    const m = /[?&]theme=(light|dark)\b/.exec(location.search);
    return m ? m[1] : 'dark';
  }

  /* 页头样式与导航条：三个页面共用，所以单独拿出来 */
  function css() {
    const s = document.createElement('style');
    s.textContent = CSS;
    document.head.appendChild(s);
    document.documentElement.dataset.theme = theme();
  }
  function nav(activeKey) {
    return NAV.map((n) =>
      `<a href="${n.href}"${n.key === activeKey ? ' class="on"' : ''}>${n.label}</a>`).join('');
  }

  function mount(dirKey) {
    const D = window.NTT_DATA;
    if (!D) {
      document.body.innerHTML =
        "<p style='padding:20px'>读不到 <code>data/vectors.js</code> —— " +
        "先在仓库根目录跑 <code>node demo/gen_layers.mjs</code>。</p>";
      return;
    }
    const dir = D.dirs[dirKey];
    if (!dir) {
      document.body.innerHTML = "<p style='padding:20px'>数据里没有方向 <code>" +
        dirKey + "</code>。</p>";
      return;
    }

    const N = D.meta.n;
    const STEPS = dir.steps;
    const NS = STEPS.length;

    /* ---- 页面骨架 ------------------------------------------------------ */
    css();

    document.title = 'ML-KEM ' + dir.name + '（' + dir.abbr + '）逐层演示';

    document.body.innerHTML = `
      <header>
        <h1>ML-KEM 的 ${dir.name}（${dir.abbr}）—— 按一下走一步</h1>
        <div class="sub">
          q = ${D.meta.q} ｜ N = ${N} ｜ ${dir.butterfly} 蝶形 ｜
          twiddle 取自同一张 <code>zetas[]</code>，正逆方向相反
        </div>
      </header>
      <nav>${nav(dirKey)}</nav>
      <main>
        <div>
          <div class="bar">
            <button id="prev">← 上一步</button>
            <button id="next">下一步 →</button>
            <button id="reset">重置</button>
            <select id="vec"></select>
          </div>
          <div class="stage" id="stage"></div>
          <div style="height:10px"></div>
          <div class="grid" id="grid"></div>
        </div>
        <div class="panel">
          <div class="box"><h2>这一步在干什么</h2><dl class="kv" id="stepinfo"></dl></div>
          <div class="box"><h2>选一个数看它的蝶形</h2><table class="bf" id="bf"></table></div>
          <div class="box"><h2>图例</h2><div class="legend">
            <span class="swatch" style="background:var(--hot-bg);border:1px solid var(--hot)"></span>
            这一步值变了
            <span class="swatch" style="background:var(--sel);border:1px solid var(--accent)"></span>
            你选中的数
            <span class="swatch" style="border:1px dashed var(--accent)"></span> 它的配对<br><br>
            每组蝶形：<br><code>${FORMULA[dirKey].big}</code><br>
            ${FORMULA[dirKey].note}<br><br>
            ⚠️ <code>fqmul</code> 是 <b>Montgomery 乘</b>，自带 <b>R⁻¹ = 169</b> 的因子；
            表里的 <code>zeta</code> 本身又是 Montgomery 域的值（<code>zetas[0] = 2285 = R</code>）。
            所以 <code>t</code> <b>不等于</b>普通的 <code>zeta × b</code> —— 两个因子正好抵消，
            真实的 twiddle 乘法在 <code>fqmul</code> 之后才成立。<br>
            数字口径：<b>canonical mod q</b>，落回 <b>0..3328</b>。
          </div></div>
          <div class="box"><h2>数据从哪来</h2><div class="legend" id="meta"></div></div>
        </div>
      </main>
      <footer id="foot"></footer>
    `;

    const els = {
      grid: document.getElementById('grid'),
      stage: document.getElementById('stage'),
      info: document.getElementById('stepinfo'),
      bf: document.getElementById('bf'),
      vec: document.getElementById('vec'),
      meta: document.getElementById('meta'),
      foot: document.getElementById('foot'),
      prev: document.getElementById('prev'),
      next: document.getElementById('next'),
      reset: document.getElementById('reset')
    };

    /* ---- 页面自检：按上面写的算式，把显示出来的数全部复算一遍 ---------- */
    const selfCheck = (() => {
      let checked = 0, bad = 0;
      for (const V of dir.vectors) {
        for (let s = 0; s < NS; s++) {
          const prev = V.snaps[s], cur = V.snaps[s + 1], st = STEPS[s];
          if (st.kind === 'scale') {
            for (let j = 0; j < N; j++) {
              checked++;
              if (canon(fqmul(prev[j], st.f)) !== cur[j]) bad++;
            }
            continue;
          }
          for (let i = 0; i < N; i++) {
            const { a, b, zeta } = geometry(s, i);
            let want;
            if (dirKey === 'ntt') {
              const t = fqmul(zeta, prev[b]);
              want = (i === a) ? canon(prev[a] + t) : (i === b) ? canon(prev[a] - t) : prev[i];
            } else {
              const t = prev[a];
              want = (i === a) ? canon(prev[a] + prev[b])
                   : (i === b) ? canon(fqmul(zeta, i16(prev[b] - t))) : prev[i];
            }
            checked++;
            if (want !== cur[i]) bad++;
          }
        }
      }
      return { checked, bad };
    })();

    const truthOk = (() => {
      let ok = 0;
      for (const V of dir.vectors) {
        const last = V.snaps[NS];
        let good = true;
        for (let i = 0; i < N; i++) if (last[i] !== V.expected[i]) { good = false; break; }
        if (good) ok++;
      }
      return ok;
    })();

    /* ---- 几何：本步里下标 i 属于哪一组、配谁、用哪个 zeta ----------------- */
    function geometry(s, i) {
      const st = STEPS[s];
      const L = st.len;
      const g = Math.floor(i / (2 * L));
      const base = g * 2 * L;
      const a = base + (i - base) % L;
      const b = a + L;
      const zetaIdx = (dirKey === 'ntt') ? st.zetaFrom + g : st.zetaFrom - g;
      return { L, g, base, a, b, zeta: D.zetas[zetaIdx], zetaIdx };
    }

    let vIdx = 0;
    let step = 0;
    let sel = null;

    dir.vectors.forEach((v) => {
      const o = document.createElement('option');
      o.value = v.id;
      o.textContent = '向量 ' + String(v.id).padStart(2, '0');
      els.vec.appendChild(o);
    });

    for (let i = 0; i < N; i++) {
      const d = document.createElement('div');
      d.className = 'cell';
      d.addEventListener('click', () => { sel = (sel === i ? null : i); render(); });
      els.grid.appendChild(d);
    }

    function render() {
      const V = dir.vectors[vIdx];
      const cur = V.snaps[step];
      const prev = step > 0 ? V.snaps[step - 1] : null;
      const st = step > 0 ? STEPS[step - 1] : null;
      const cs = els.grid.children;
      const isLayer = st && st.kind === 'layer';

      for (let i = 0; i < N; i++) {
        const c = cs[i];
        const changed = prev && cur[i] !== prev[i];
        let cls = 'cell' + (step > 0 ? ' on' : '');
        if (changed) cls += ' chg';
        if (sel === i) cls += ' sel';
        else if (isLayer && sel !== null && geometry(step - 1, i).g === geometry(step - 1, sel).g) cls += ' pair';
        c.className = cls;
        c.textContent = cur[i];
        c.title = '下标 ' + i + ' ｜ 十进制 ' + cur[i] + ' ｜ 十六进制 ' + hex3(cur[i]);
      }

      if (step === 0) {
        els.stage.innerHTML = '状态：<b>输入</b>（还没开始）';
        els.info.innerHTML = '<dt>步</dt><dd>0 / ' + NS + '</dd>' +
          '<dt>说明</dt><dd>这 256 个数就是待变换的多项式系数。</dd>';
      } else {
        const changed = prev.reduce((n, x, i) => n + (x !== cur[i] ? 1 : 0), 0);
        els.stage.innerHTML = '状态：第 <b>' + step + '</b> / ' + NS + ' 步已经走完';
        let html = '<dt>步</dt><dd>' + step + ' / ' + NS + '</dd>';
        if (st.kind === 'scale') {
          html += '<dt>性质</dt><dd>末级缩放（不是蝶形）</dd>' +
                  '<dt>算式</dt><dd><code>r′ = fqmul(r, ' + st.f + ')</code></dd>' +
                  '<dt>等价于</dt><dd><code>r × 512</code>（512 = R/128，mont 域口径）</dd>';
        } else {
          html += '<dt>蝶形</dt><dd>' + dir.butterfly + '</dd>' +
                  '<dt>len</dt><dd>' + st.len + '（每组 ' + st.len + ' 个蝶形）</dd>' +
                  '<dt>组数</dt><dd>' + st.groups + '</dd>' +
                  '<dt>twiddle</dt><dd><code>zetas[' + st.zetaFrom + '] → [' + st.zetaTo + ']</code>' +
                  (dirKey === 'ntt' ? '（递增）' : '（递减）') + '</dd>';
        }
        html += '<dt>本步数值变了</dt><dd>' + changed + ' / ' + N + ' 个</dd>';
        els.info.innerHTML = html;
      }

      renderButterfly(cur, prev, st);
    }

    function renderButterfly(cur, prev, st) {
      const row = (k, v) => '<tr><td>' + k + '</td><td class="v">' + v + '</td></tr>';
      if (step === 0) {
        els.bf.innerHTML = '<tr><td class="legend">先按「下一步」，再点格子。</td></tr>';
        return;
      }
      if (sel === null) {
        els.bf.innerHTML = '<tr><td class="legend">点左边的格子。</td></tr>';
        return;
      }
      if (st.kind === 'scale') {
        els.bf.innerHTML =
          row('你点的下标', sel + '（这一步 256 个系数各算一次，没有配对）') +
          row('本步前', prev[sel] + '（十六进制 ' + hex3(prev[sel]) + '）') +
          row('本步后', cur[sel] + '（十六进制 ' + hex3(cur[sel]) + '）') +
          row('算式', '<code>r′ = fqmul(r, ' + st.f + ')</code><br>' +
                      '等价于 <code>r′ = r × 512 mod q</code> —— ' +
                      '512 = R/128，这一步把 Montgomery 因子 R 引了进来');
        return;
      }

      const G = geometry(step - 1, sel);
      let html =
        row('你点的下标', sel + '（第 ' + (sel - G.base + 1) + ' / ' + (2 * G.L) + ' 个）') +
        row('所属组', '第 ' + G.g + ' 组，覆盖下标 ' + G.base + ' .. ' + (G.base + 2 * G.L - 1)) +
        row('本组的 zeta', '<code>zetas[' + G.zetaIdx + '] = ' + G.zeta + '</code>') +
        row('a（下标 ' + G.a + '）', cur[G.a] + '（本步前 ' + prev[G.a] + '）') +
        row('b（下标 ' + G.b + '）', cur[G.b] + '（本步前 ' + prev[G.b] + '）');

      if (dirKey === 'ntt') {
        const t = canon(fqmul(G.zeta, prev[G.b]));
        html += row('蝶形',
          '<code>t = fqmul(zeta, b) = ' + t + '</code><br>' +
          '<code>a′ = a + t = ' + prev[G.a] + ' + ' + t + ' = ' + cur[G.a] + '</code><br>' +
          '<code>b′ = a − t = ' + prev[G.a] + ' − ' + t + ' = ' + cur[G.b] + '</code>');
      } else {
        const t = prev[G.a];
        html += row('蝶形',
          '<code>t = a = ' + t + '</code><br>' +
          '<code>a′ = a + b = ' + prev[G.a] + ' + ' + prev[G.b] + ' = ' + cur[G.a] + '</code><br>' +
          '<code>b′ = fqmul(zeta, b − t) = ' + cur[G.b] + '</code>');
      }
      els.bf.innerHTML = html;
    }

    function stepBy(d) {
      step = Math.max(0, Math.min(NS, step + d));
      render();
    }
    els.next.addEventListener('click', () => stepBy(1));
    els.prev.addEventListener('click', () => stepBy(-1));
    els.reset.addEventListener('click', () => { step = 0; sel = null; render(); });
    els.vec.addEventListener('change', (e) => {
      vIdx = +e.target.value; step = 0; sel = null; render();
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight') { stepBy(1); e.preventDefault(); }
      if (e.key === 'ArrowLeft')  { stepBy(-1); e.preventDefault(); }
      if (e.key === 'r') { step = 0; sel = null; render(); }
    });

    els.prev.disabled = false;
    els.meta.innerHTML =
      '层序规则：<code>' + D.meta.layerOrderSource + '</code><br>' +
      'zeta 表：<code>' + D.meta.zetaSource + '</code><br>' +
      '真值来源：<code>' + D.meta.groundTruth + '</code><br>' +
      '对齐情况：<b class="ok">末级 ' + truthOk + '/' + dir.vectors.length + ' 组与真值逐值一致</b><br>' +
      '页面自检：<b class="ok">按本页写出的算式复算 ' + selfCheck.checked + ' 个值，不符 ' +
        selfCheck.bad + ' 个</b><br>' +
      (dirKey === 'intt' ? '往返关系：<code>' + D.meta.invariant + '</code><br>' : '') +
      '生成器：<code>' + D.meta.generator + '</code>';

    els.foot.innerHTML = dirKey === 'ntt'
      ? '本页只做<b>正变换</b>。第 7 步之后就是 NTT 的结果，' +
        '与 <code>research/mlkem_kat/ntt_out.hex</code> 逐值对齐。'
      : '本页做<b>逆变换</b>。输入就是正变换的输出（同一份数据），' +
        '末级多一步逐系数缩放 <code>f = 1441</code>；与 ' +
        '<code>research/mlkem_kat/intt_out.hex</code> 逐值对齐。';

    render();
  }

  window.NttView = { mount: mount, css: css, nav: nav };
})();
