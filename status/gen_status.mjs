#!/usr/bin/env node
// status/gen_status.mjs
//
// 把「项目进度」渲染成一页离线 HTML。零依赖，只用 node 内置模块。
//
//   node status/gen_status.mjs            # 生成 status/index.html
//   node status/gen_status.mjs --check    # 只跑自检，不写文件
//
// 数据分两半：
//   AUTO   —— 每次重跑现抓（git 提交、文件与行数、文档自称的更新日期、倒计时）
//   MANUAL —— 人的判断，写在 status/status.json 里（下一步、卡点、里程碑）
//
// 页面上的每个数字都能追到来源：AUTO 的给命令，MANUAL 的给 status.json 里的 source。
// 出处见文件末尾的「数据来源」表，以及每个数字上的 title 提示。

import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const OUT = join(HERE, 'index.html');
const CHECK_ONLY = process.argv.includes('--check');

// ─────────────────────────────────────────────────────────── 小工具

const MS_DAY = 86400000;
const dayOf = (y, m, d) => Date.UTC(y, m - 1, d) / MS_DAY;
const todayUTC = () => { const n = new Date(); return dayOf(n.getFullYear(), n.getMonth() + 1, n.getDate()); };
const TODAY = todayUTC();

/** 从任意字符串里取第一个 YYYY-MM-DD，返回「距离今天多少天」。没有就返回 null。 */
function daysSinceDateIn(text) {
  const m = /(\d{4})-(\d{2})-(\d{2})/.exec(text || '');
  if (!m) return null;
  return TODAY - dayOf(+m[1], +m[2], +m[3]);
}
const mdLabel = (s) => {
  const m = /(\d{4})-(\d{2})-(\d{2})/.exec(s || '');
  return m ? `${m[2]}-${m[3]}` : (s || '');
};

function git(args) {
  try {
    return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
}
function readUtf8(rel) {
  try { return readFileSync(join(ROOT, rel), 'utf8'); } catch { return null; }
}
function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
const pct = (a, b) => (b > 0 ? Math.round((a / b) * 1000) / 10 : 0);
const DAY = 86400000;
/** 'YYYY-MM-DD' → 第几天（整数，跨月跨年都正确）。 */
const dayNum = (iso) => dayOf(+iso.slice(0, 4), +iso.slice(5, 7), +iso.slice(8, 10));
const addDays = (iso, n) => new Date((dayNum(iso) + n) * DAY).toISOString().slice(0, 10);

// ─────────────────────────────────────────────────────────── AUTO：现抓

/** git 提交：每个人的最后一次提交、近 7 天提交数、总提交数。 */
function collectGitActivity(tracks) {
  const raw = git(['log', '--format=%an|%ae|%ad', '--date=short']);
  const rows = raw ? raw.split('\n').filter(Boolean).map((l) => l.split('|')) : [];
  return tracks.map((t) => {
    const mine = rows.filter(([name, mail]) =>
      t.git_authors.some((a) => a === name || a.toLowerCase() === (mail || '').toLowerCase()));
    const last = mine.length ? mine[0][2] : null;          // git log 默认新→旧
    const lastDays = last ? TODAY - dayOf(+last.slice(0, 4), +last.slice(5, 7), +last.slice(8, 10)) : null;
    // ⚠️ 2026-10-15 订正：`<= 7` 数的是**含今天在内的 8 天**（今天 − 提交日 ≤ 7），
    //    而这一栏在页面上写的是「近 7 天」—— 差一天，正好把 10-08 那天也算进来，
    //    于是 A 显示「近 7 天 16 次」（那 16 次全是 10-08 当天的），与「A 自 10-08 起
    //    没再提交」的实况看着正好相反。改成 `< 7`：今天与往前 6 天，共 7 个日历日。
    const in7 = mine.filter(([, , d]) => TODAY - dayOf(+d.slice(0, 4), +d.slice(5, 7), +d.slice(8, 10)) < 7).length;
    return { id: t.id, last, lastDays, in7, total: mine.length };
  });
}

/** 仓库当前状态：分支、领先/落后远端、未提交、上次 fetch 是什么时候。 */
function collectRepoState() {
  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD']) || '(未知)';
  const aheadRaw = git(['rev-list', '--count', '@{u}..HEAD']);
  const behindRaw = git(['rev-list', '--count', 'HEAD..@{u}']);
  const porcelain = git(['status', '--porcelain']);
  const dirty = porcelain ? porcelain.split('\n').filter(Boolean) : [];
  let fetchAge = null;
  try {
    fetchAge = Math.floor((Date.now() - statSync(join(ROOT, '.git', 'FETCH_HEAD')).mtimeMs) / MS_DAY);
  } catch { /* 没 fetch 过就没有 */ }
  return {
    branch,
    ahead: aheadRaw === '' ? null : +aheadRaw,
    behind: behindRaw === '' ? null : +behindRaw,
    dirty,
    fetchAge,
  };
}

const CODE_EXT = ['.v', '.sv', '.vh', '.py', '.md', '.mjs', '.js', '.html', '.css', '.sh', '.tcl'];
const SKIP_PATH = ['_scratch', '_broken', '_failed_attempts', 'batch/'];

/** 目录规模：跟踪的文件数 + 源码/文档行数（不含数据文件与草稿目录）。 */
function collectDirStats() {
  const dirs = [
    ['rtl/ntt_core', 'NTT 核（参数化版）'],
    ['rtl/probes', '验证探针'],
    ['rtl/vivado', '综合脚本与报告'],
    ['host/src', '上位机（B）'],
    ['refsim/pe1', '验证台（B）'],
    ['report/design', '报告正文（C）'],
    ['demo', '演示页（C）'],
    ['skill', '技能包（C）'],
    ['metrics', '指标表（C）'],
  ];
  return dirs.map(([dir, label]) => {
    const listed = git(['-c', 'core.quotePath=false', 'ls-files', dir]).split('\n').filter(Boolean);
    const keep = listed.filter((p) => !SKIP_PATH.some((s) => p.includes(s)) && CODE_EXT.some((e) => p.endsWith(e)));
    let lines = 0;
    for (const p of keep) {
      const txt = readUtf8(p);
      if (txt) lines += txt.split('\n').length - (txt.endsWith('\n') ? 1 : 0);
    }
    return { dir, label, files: keep.length, lines, exists: listed.length > 0 };
  });
}

/** 文档新鲜度：取每份文档头部第一个 YYYY-MM-DD，当「它自称的更新日期」。 */
function collectDocFreshness() {
  const docs = [
    ['logs/project_state.md', '入口记录（每次开工读它）'],
    ['logs/schedule_plain.md', '通俗版排期'],
    ['team/todo_AB.md', 'A、B 待办清单'],
    ['team/todo_C.md', 'C 待办与阻塞'],
    ['team/guide_A.md', 'A 引导与计划'],
    ['team/guide_B.md', 'B 引导与计划'],
    ['team/guide_C.md', 'C 引导与计划'],
    ['rtl/folding_param_plan.md', '参数化版本计划'],
    ['rtl/H1_port_spec.md', 'H1 端口说明'],
    ['rtl/vivado/folding_comparison.md', '三档综合对比表'],
    ['host/proto.md', 'H3 串口协议（已冻结）'],
    ['refsim/README.md', '验证台说明'],
  ];
  return docs.map(([rel, label]) => {
    const txt = readUtf8(rel);
    if (txt === null) return { rel, label, stale: null, date: null, from: null, exists: false };
    const head = txt.split('\n').slice(0, 25).join('\n');
    const m = /(\d{4}-\d{2}-\d{2})/.exec(head);
    let date = m ? m[1] : null;
    let from = m ? 'doc' : null;
    let age = daysSinceDateIn(head);
    if (age === null) {                       // 文档自己不写日期 → 退回 git 最后改动
      const g = git(['log', '-1', '--format=%ad', '--date=short', '--', rel]);
      if (g) { date = g; from = 'git'; age = TODAY - dayOf(+g.slice(0, 4), +g.slice(5, 7), +g.slice(8, 10)); }
    }
    return { rel, label, stale: age, date, from, exists: true };
  });
}

// ─────────────────────────────────────────────────────────── 渲染

const STATE = {
  done: { icon: '✓', text: '已完成', cls: 'st-done' },
  doing: { icon: '▶', text: '进行中', cls: 'st-doing' },
  todo: { icon: '○', text: '待办', cls: 'st-todo' },
  blocked: { icon: '⚠', text: '卡住', cls: 'st-blocked' },
};
const stateOf = (k) => STATE[k] || STATE.todo;

/** 文档过期阈值：≤3 天新鲜，4–7 天要留意，>7 天过期。 */
const dot = (color) => `<span class="dot" style="background:var(--${color})"></span>`;

function staleChip(days) {
  if (days === null) return '<span class="chip">无日期</span>';
  if (days <= 3) return `<span class="chip">${dot('good')}✓ 新鲜 · ${days} 天前</span>`;
  if (days <= 7) return `<span class="chip">${dot('warn')}▶ 要留意 · ${days} 天前</span>`;
  return `<span class="chip">${dot('crit')}⚠ 过期 · ${days} 天前</span>`;
}

// ─────────────────────────────────────────── 主图：甘特图

/**
 * 把 status.json 的 gantt 段画成一张甘特图。
 * 横轴是真实日期（span = 最早一周的头 → 最后一周的尾），竖轴是 A/B/C 三条线，一行一周。
 * 条的颜色 = 哪条线（--hc），条的填充方式 = 什么状态；这两套编码分开，灰度打印也读得出来。
 * 返回 null 表示没有 gantt 数据（页面照常渲染，只是不画图）。
 */
function buildGantt(json, activity) {
  const g = json.gantt || {};
  const weeks = g.weeks || [];
  const bars = g.bars || [];
  const handoffs = g.handoffs || [];
  if (!weeks.length || !bars.length) return null;

  const spanA = Math.min(...weeks.map((w) => dayNum(w.start)));
  const spanB = Math.max(...weeks.map((w) => dayNum(w.end))) + 1;   // 末日也算进去
  const total = spanB - spanA;
  const X = (iso) => ((dayNum(iso) - spanA) / total) * 100;         // 日期 → 横向百分比
  const W = (a, b) => X(addDays(b, 1)) - X(a);                      // 含末日的宽度

  const wkOf = Object.fromEntries(weeks.map((w) => [w.id, w]));
  const span = (spec) => {                                          // 'W3' 或 'W3-W5'
    const [a, b] = String(spec).split('-');
    return [wkOf[a] || wkOf[b], wkOf[b || a] || wkOf[a]];
  };

  // 被卡住的条：blockers 里写了 bar:{track,week} 的，挂到对应的条上
  const blockedAt = {};
  for (const b of json.blockers || []) {
    if (!b.bar) continue;
    const k = b.bar.track + '|' + b.bar.week;
    (blockedAt[k] = blockedAt[k] || []).push(b);
  }

  const pos = (w) => `left:${X(w.start).toFixed(3)}%;width:${W(w.start, w.end).toFixed(3)}%`;

  const axis = weeks.map((w) =>
    `<div class="gwk" style="${pos(w)}"><b>${esc(w.id)}</b><span>${esc(mdLabel(w.start))}</span></div>`).join('');

  const grid = weeks.slice(1).map((w) => `<div class="gline" style="left:${X(w.start).toFixed(3)}%"></div>`).join('');
  const bands = handoffs.map((h) => {
    const w = wkOf[h.week];
    return w ? `<div class="gband${h.key ? ' key' : ''}" style="${pos(w)}"></div>` : '';
  }).join('');
  const tp = X(isoToday());
  const nowLine = tp >= 0 && tp <= 100 ? `<div class="gnow" style="left:${tp.toFixed(3)}%"></div>` : '';

  const handRow = handoffs.length ? `<div class="grow ghand"><div class="glab">交接点</div><div class="gtrack">${
    handoffs.map((h) => {
      const w = wkOf[h.week];
      if (!w) return '';
      return `<div class="ghchip${h.key ? ' key' : ''}${h.state === 'done' ? ' done' : ''}" style="${pos(w)}" title="${esc(h.label)}">${esc(h.ids)}</div>`;
    }).join('')}</div></div>` : '';

  const sections = (json.tracks || []).map((t) => {
    const mine = bars.filter((b) => b.track === t.id)
      .sort((a, b) => dayNum(span(a.week)[0].start) - dayNum(span(b.week)[0].start));
    if (!mine.length) return '';
    const a = activity.find((x) => x.id === t.id) || {};
    const head = `<div class="gsec">
      <div class="glab"><span class="swatch" style="--c:var(--s${t.color})"></span>${esc(t.name)}</div>
      <div class="gact">最后提交 ${esc(a.last ? mdLabel(a.last) : '无')} · 近 7 天 ${a.in7 ?? 0} 次 · 累计 ${a.total ?? 0} 次</div>
    </div>`;
    const rows = mine.map((b) => {
      const [wa, wb] = span(b.week);
      if (!wa) return '';
      const bl = blockedAt[b.track + '|' + b.week];
      const title = [b.note, b.source && `出处 ${b.source}`,
        bl && `卡在这：${bl.map((x) => `${x.from}→${x.to} ${x.what}`).join('；')}`].filter(Boolean).join(' ｜ ');
      const chips = (b.critical ? '<span class="tkey">关键</span>' : '')
        + (bl ? `<span class="twarn" title="${esc(bl.map((x) => x.what).join('；'))}">⚠</span>` : '');
      const geom = `left:${X(wa.start).toFixed(3)}%;width:${W(wa.start, wb.end).toFixed(3)}%`;
      return `<div class="grow">
        <div class="glab"><span class="glab-t" title="${esc(b.note)}">${esc(b.label)}</span>${chips}</div>
        <div class="gtrack">${b.critical ? `<div class="ghalo" style="${geom}"></div>` : ''}<div class="gbar st-${esc(b.state)}${bl ? ' is-blocked' : ''}"
          style="--hc:var(--s${t.color});${geom}"
          title="${esc(title)}"><i></i></div></div>
      </div>`;
    }).join('');
    return head + rows;
  }).join('');

  return { axis, grid, bands, nowLine, handRow, sections };
}

function tile(label, value, note, prov, asOf) {
  const title = `${prov}${asOf ? ` · 核对日期 ${asOf}` : ''}`;
  return `<div class="tile" title="${esc(title)}">
    <div class="tile-l">${esc(label)}</div>
    <div class="tile-v">${esc(value)}</div>
    <div class="tile-n">${esc(note)}</div>
    <div class="tile-p">${esc(prov)}${asOf ? ` · ${esc(asOf)}` : ''}</div>
  </div>`;
}

function render(data) {
  const { json, activity, repo, dirStats, docs } = data;
  const cd = json.countdown;
  const subDays = daysSinceDateIn(cd.submission) * -1;
  const ms = json.milestones;
  const doneCount = ms.filter((m) => m.state === 'done').length;

  // ── 交付进度（英雄数字）────────────────────────────────────────────
  // 分母＝甘特图那 N 根「周计划」条（每根＝一条线一周的活），不是里程碑。
  // 用甘特作分母是为了让英雄数字与整页主图**同口径** —— 主图上数一数就知道
  // 这个百分比是怎么来的。里程碑 8/14 另在下面的 KPI 数字块里，两个不相加。
  const bars = json.gantt?.bars || [];
  const barTotal = bars.length;
  const barDone = bars.filter((b) => b.state === 'done').length;
  const barDoing = bars.filter((b) => b.state === 'doing').length;
  const barPct = pct(barDone, barTotal);
  const barPctWithDoing = pct(barDone + barDoing, barTotal);
  // ── 日历进度（对照线）──────────────────────────────────────────────
  // 起点＝W0 首日；终点＝**截止日**（不是 W7 末日 —— W7 已越过截止，见 gantt.note）。
  const wk0 = json.gantt?.weeks?.[0];
  const planFrom = wk0 ? wk0.start : null;
  const dayTotal = planFrom ? dayNum(cd.submission) - dayNum(planFrom) + 1 : null;
  const dayPassed = planFrom
    ? Math.min(Math.max(TODAY - dayNum(planFrom) + 1, 0), dayTotal) : null;
  const dayPct = dayTotal ? pct(dayPassed, dayTotal) : null;
  // gap ＝ 已交付 − 应到。**负数是落后**（交付的百分比没跟上时间流逝的百分比）。
  const gap = dayTotal ? Math.round((barPct - dayPct) * 10) / 10 : null;
  const paceWord = gap === null ? ''
    : gap <= -5 ? `｜已交付落后日历 ${Math.abs(gap)} 个点${barDoing ? `，差额在 ${barDoing} 条进行中` : ''}`
    : gap >= 5 ? `｜已交付领先日历 ${gap} 个点`
    : '｜与日历基本同步';

  // 入口记录的新鲜度单独拎出来当头条（它是每次开工读的第一份文件）
  const entry = docs.find((d) => d.rel.includes('project_state.md') && d.rel.startsWith('logs/'));
  const entryHead = entry && entry.stale !== null
    ? `<div class="fresh${entry.stale > 7 ? ' crit' : entry.stale > 3 ? ' warn' : ''}">${
        dot(entry.stale > 7 ? 'crit' : entry.stale > 3 ? 'warn' : 'good')}${
        entry.stale > 3 ? '⚠' : '✓'} 入口记录停在 ${esc(mdLabel(entry.date))} · 已 ${entry.stale} 天没更新</div>` : '';

  const totalCommits = activity.reduce((n, a) => n + (a.total || 0), 0);
  const tiles = [
    tile('关键路径里程碑', `${doneCount}/${ms.length}`, '已完成 / 全部', '自动 · status.json', json.updated),
    ...(json.manual_numbers || []).map((n) => tile(n.label, n.value, n.note, `人写 · ${n.source}`, n.as_of)),
    tile('三人提交', String(totalCommits), `A ${activity[0]?.total ?? 0} · B ${activity[1]?.total ?? 0} · C ${activity[2]?.total ?? 0}`,
      '自动 · git log', null),
  ];

  const scaleLine = dirStats.filter((d) => d.exists)
    .map((d) => `${d.label} ${d.lines.toLocaleString('en-US')} 行`).join(' · ');

  const nows = json.tracks.map((t) => `<article class="now" style="--c: var(--s${t.color})">
      <div class="now-h"><span class="swatch" aria-hidden="true"></span>${esc(t.name)}</div>
      <div class="now-b">
        <span class="k">现在</span><span class="v">${esc(t.now)}</span>
        <span class="k">下一步</span><span class="v">${esc(t.next)}</span>
      </div>
      <div class="now-p" title="${esc(t.source)}">范围 ${esc(t.scope)} · 来源 ${esc(t.source)} · 核对 ${esc(t.as_of)}</div>
    </article>`).join('');

  const ganttNote = json.gantt?.note ? `<p class="gnote">⚠ ${esc(json.gantt.note)}</p>` : '';
  const gan = buildGantt(json, activity);
  const ganttHtml = gan ? `
<p class="glegend">
  <span class="k"><span class="gsw gsw-done"></span>已完成</span>
  <span class="k"><span class="gsw gsw-doing"><i></i></span>进行中</span>
  <span class="k"><span class="gsw gsw-todo"></span>计划中</span>
  <span class="k"><span class="gsw gsw-blocked"></span>被卡住</span>
  <span class="k"><span class="gsw gsw-crit"></span>关键路径 —— 这几根不交，后面的动不了</span>
  <span class="k">竖线＝今天 ${esc(isoToday())}</span>
</p>
<div class="gwrap"><div class="gantt">
  <div class="grow ghead"><div class="glab">部门 / 周次</div><div class="gtrack">${gan.axis}</div></div>
  <div class="gbody">
    <div class="gbg" aria-hidden="true">${gan.grid}${gan.bands}</div>
    <div class="gnowlay" aria-hidden="true">${gan.nowLine}</div>
    ${gan.handRow}
    ${gan.sections}
  </div>
</div></div>` : '<p class="hint">status.json 里还没有 gantt 段，主图未生成。</p>';

  const blockers = json.blockers.map((b) => `<article class="blk">
      <div class="blk-who"><span class="who">${esc(b.from)}</span><span class="arrow">欠</span><span class="who">${esc(b.to)}</span></div>
      <div class="blk-what">${esc(b.what)}</div>
      <div class="blk-imp"><span class="k">影响</span>${esc(b.impact)}</div>
      <div class="blk-p" title="${esc(b.source)}">出处 ${esc(b.source)} · 核对 ${esc(b.as_of)}</div>
    </article>`).join('');

  const todoRows = json.todos.map((t) => {
    const s = stateOf(t.state);
    return `<tr data-owner="${esc(t.owner)}" class="${s.cls}">
      <td class="c-owner"><span class="owner-dot" style="--c: var(--s${ownerColor(json, t.owner)})"></span>${esc(t.owner)}</td>
      <td>${esc(t.text)}</td>
      <td class="c-state"><span class="ico">${s.icon}</span>${s.text}</td>
      <td class="c-src" title="${esc(t.source)}">${esc(t.source)}</td>
    </tr>`;
  }).join('');

  const docRows = docs.map((d) => `<tr>
      <td>${esc(d.rel)}</td>
      <td class="c-dim">${esc(d.label)}</td>
      <td class="c-num">${d.date ? esc(d.date) + (d.from === 'git' ? ' <span class="c-dim">(git)</span>' : '') : '—'}</td>
      <td>${d.exists ? staleChip(d.stale) : `<span class="chip">${dot('crit')}⚠ 文件不存在</span>`}</td>
    </tr>`).join('');

  const provRows = [
    ['提交活动（最后提交 / 近 7 天 / 累计）+ 分支与领先落后 + 未提交文件', '自动', 'git log --format=%an|%ae|%ad ；git rev-list --count @{u}..HEAD ；git status --porcelain'],
    ['目录规模（文件数 / 源码与文档行数）', '自动', 'git ls-files <目录>（跳过 _scratch / _broken / _failed_attempts / batch/，只数 .v .py .md .mjs .html .sh .tcl 等）'],
    ['文档新鲜度（各文档自称的更新日期与已过天数）', '自动', '读每份文档头 25 行取第一个 YYYY-MM-DD；取不到则退回 git log -1 --format=%ad -- <该文件>（表里标 (git)）'],
    ['倒计时（距作品提交 / 决赛）', '自动', '本机当前日期 与 status.json 的 countdown 相减'],
    ['★ 顶部那个百分比（已交付）', '自动', 'status.json 的 gantt.bars —— 分母是**甘特图上条子的总数**（3 条线 × 表上的周数），分子是 state=done 的条数。**与下面主图同口径，主图上数一数就能核**。空心段＝state=doing，「含则 x%」是 done+doing。⚠️ 与 KPI 块里的「关键路径里程碑」**不同口径，两个数不要相加**'],
    ['对照线「按日历应到」', '自动', '（今天 − W0 首日 + 1）÷（countdown.submission − W0 首日 + 1）。终点取**截止日**，不是表上最后一个周次的末日 —— 见 status.json 的 gantt.note'],
    ['主图横轴（周次与日期）', '人写', 'status/status.json 的 gantt.weeks —— **2026-10-07 重切过**（原 W0–W7 里 W3 之后大半在写已经做完的事，且 W7 整周越过截止），重切理由见 gantt.note'],
    ['主图每一根条（做什么 / 什么状态 / 是否关键路径）', '人写', 'status/status.json 的 gantt.bars，每根的 note 与 source 抄自上述三张表的对应周行'],
    ['主图上的 ⚠（哪根条被卡住）', '人写', 'status.json 的 blockers[].bar 指到具体哪根条，图与下面的「欠账」是同一份数据'],
    ['主图上的竖线（今天）', '自动', '本机当前日期；交接带的宽度＝那一周的真实起止'],
    ['下一步 / 卡点 / 里程碑 / 人的判断', '人写', 'status/status.json（每条自带 source 与 as_of）'],
    ['验证覆盖 / 自测项数 / 三档引脚', '人写', 'status/status.json 的 manual_numbers（数字本身在仓库里有实测出处）'],
  ].map(([what, how, src]) => `<tr><td>${esc(what)}</td><td>${esc(how)}</td><td class="c-src">${esc(src)}</td></tr>`).join('');

  const repoLine = [
    `分支 ${repo.branch}`,
    repo.ahead === null ? '无远端跟踪' : (repo.ahead === 0 && repo.behind === 0 ? '与远端一致（上次 fetch 时）'
      : `领先远端 ${repo.ahead} · 落后 ${repo.behind}（上次 fetch 时）`),
    repo.fetchAge === null ? '没 fetch 过' : `上次 fetch ${repo.fetchAge} 天前`,
    repo.dirty.length === 0 ? '工作区干净' : `工作区有 ${repo.dirty.length} 处未提交`,
  ].join(' · ');

  return `<!doctype html>
<html lang="zh-CN" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FPGA 竞赛 · 项目进度</title>
<style>
:root{
  color-scheme: light;
  --surface-1:#fcfcfb; --plane:#f9f9f7; --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,.10);
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a;
  --good:#0ca30c; --warn:#fab219; --serious:#ec835a; --crit:#d03b3b;
  --track:#86b6ef;
  --tint:rgba(11,11,11,.045); --tint-crit:rgba(208,59,59,.10);
}
@media (prefers-color-scheme: dark){:root:where(:not([data-theme="light"])){
  color-scheme: dark;
  --surface-1:#1a1a19; --plane:#0d0d0d; --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
  --s1:#3987e5; --s2:#d95926; --s3:#199e70;
  --track:#184f95;
  --tint:rgba(255,255,255,.055); --tint-crit:rgba(208,59,59,.22);
}}
:root[data-theme="dark"]{
  color-scheme: dark;
  --surface-1:#1a1a19; --plane:#0d0d0d; --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
  --s1:#3987e5; --s2:#d95926; --s3:#199e70;
  --track:#184f95;
  --tint:rgba(255,255,255,.055); --tint-crit:rgba(208,59,59,.22);
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{
  background:var(--plane); color:var(--ink);
  font:15px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;
  -webkit-font-smoothing:antialiased;
}
.wrap{max-width:1080px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:22px;margin:0 0 4px;font-weight:650;letter-spacing:.2px}
h2{font-size:15px;margin:36px 0 12px;font-weight:650;color:var(--ink)}
h2 .h2n{color:var(--muted);font-weight:400;margin-left:8px}
.sub{margin:0;color:var(--ink-2);font-size:13.5px}
.hdr{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap}
.btn{
  background:var(--surface-1);color:var(--ink-2);border:1px solid var(--border);
  border-radius:8px;padding:7px 12px;font:inherit;font-size:13px;cursor:pointer;
}
.btn:hover{color:var(--ink)}
.meta{color:var(--muted);font-size:12.5px;margin-top:10px}

/* 英雄数字：全页只有这一个 */
.hero{
  display:flex;align-items:flex-end;gap:22px;flex-wrap:wrap;
  background:var(--surface-1);border:1px solid var(--border);border-radius:14px;
  padding:22px 24px;margin-top:24px;
}
.hero-num{display:flex;align-items:baseline;gap:6px}
.hero-num .n{font-size:56px;line-height:1;font-weight:650;letter-spacing:-1px}
.hero-num .u{font-size:20px;color:var(--ink-2)}
.hero-side{padding-bottom:6px}
.hero-l{font-size:13.5px;color:var(--ink-2)}
.hero-2{font-size:13px;color:var(--muted);margin-top:2px}
.meter{position:relative;height:10px;border-radius:5px;background:var(--track);margin-top:10px;min-width:280px;overflow:hidden}
.meter-fill{position:absolute;left:0;top:0;height:100%;background:var(--s1);border-radius:5px 0 0 5px}
.meter-do{position:absolute;top:0;height:100%;background:var(--s1);opacity:.42;border-radius:0 5px 5px 0}
.meter-cap{font-size:12px;color:var(--ink-2);margin-top:6px}
.fresh{
  margin-left:auto;align-self:center;font-size:13px;padding:8px 12px;border-radius:9px;
  border:1px solid var(--border);background:var(--plane);color:var(--ink-2);
}
.fresh.warn{border-color:var(--warn)}
.fresh.crit{border-color:var(--crit)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:7px;vertical-align:middle;flex:none}

/* KPI 数字块 */
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(190px,100%),1fr));gap:12px;margin-top:12px}
.tile{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px 15px}
.tile-l{font-size:12.5px;color:var(--ink-2)}
.tile-v{font-size:26px;font-weight:650;margin:3px 0 4px;line-height:1.15}
.tile-n{font-size:12px;color:var(--ink-2);min-height:2.2em}
.tile-p{font-size:11.5px;color:var(--muted);margin-top:8px;border-top:1px solid var(--grid);padding-top:7px}
.hint{font-size:11.5px;color:var(--muted);margin:10px 0 0}
.ico{font-size:12px}

/* 三条线：压缩成两列文字，不再是三张大卡片 */
.nows{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(300px,100%),1fr));gap:12px}
.now{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:13px 15px}
.now-h{display:flex;align-items:center;gap:8px;font-weight:650;font-size:13.5px;margin-bottom:8px}
.swatch{width:10px;height:10px;border-radius:3px;background:var(--c);flex:none}
.now-b{display:grid;grid-template-columns:44px 1fr;gap:6px 9px}
.now-b .k{font-size:11.5px;color:var(--muted);padding-top:2px}
.now-b .v{font-size:13px}
.now-p{font-size:11.5px;color:var(--muted);margin-top:9px;border-top:1px solid var(--grid);padding-top:7px}

/* ═══ 主图：甘特图 ═══
   色相＝哪条线（s1/s2/s3），填充方式＝什么状态（实心/半透/空心/虚线）。
   两套编码分开，所以灰度打印也读得出来。 */
.glegend{font-size:12.5px;color:var(--ink-2);margin:0 0 10px;line-height:1.9}
.glegend .k{margin-right:16px;white-space:nowrap;display:inline-block}
.gnote{font-size:12.5px;color:var(--ink-2);background:var(--surface-1);border:1px solid var(--warn);border-left-width:3px;border-radius:10px;padding:10px 13px;margin:0 0 12px;line-height:1.75}
.gsw{display:inline-block;width:20px;height:11px;border-radius:3px;vertical-align:-1px;margin-right:5px;overflow:hidden}
.gsw i{display:block;height:100%}
.gsw-done{background:var(--ink-2)}
.gsw-doing{border:1.5px solid var(--ink-2)}
.gsw-doing i{background:var(--ink-2);opacity:.45}
.gsw-todo{border:1.5px solid var(--ink-2);opacity:.5}
.gsw-blocked{border:1.5px dashed var(--warn)}
.gsw-crit{background:var(--tint-crit);border-left:3px solid var(--crit)}
.gwrap{overflow-x:auto;border:1px solid var(--border);border-radius:12px;background:var(--surface-1)}
.gantt{min-width:780px}
.grow{display:grid;grid-template-columns:196px 1fr;align-items:center;min-height:25px;position:relative;z-index:1}
.glab{position:sticky;left:0;z-index:3;background:var(--surface-1);display:flex;align-items:center;gap:5px;
  font-size:12.5px;color:var(--ink-2);padding:2px 8px 2px 12px;height:100%;
  border-right:1px solid var(--grid);white-space:nowrap}
.glab-t{overflow:hidden;text-overflow:ellipsis;flex:1 1 auto}
.tkey{flex:none;font-size:10px;color:var(--crit);border:1px solid var(--crit);border-radius:99px;padding:0 5px}
.twarn{flex:none;font-size:11px;color:var(--warn)}
.gtrack{position:relative;height:25px}
.gbar{position:absolute;top:5.5px;height:14px;border-radius:4px;border:1.5px solid var(--sc);overflow:hidden}
.gbar i{display:block;height:100%;background:var(--sc)}
.gbar.st-done{--sc:var(--hc)}
.gbar.st-doing{--sc:var(--hc)}
.gbar.st-doing i{opacity:.45}
.gbar.st-todo{--sc:var(--hc);opacity:.55}
.gbar.st-todo i{background:transparent}
.gbar.is-blocked{border:1.5px dashed var(--warn)}
/* 关键路径：条背后一层浅色底。相邻周连在一起，就成了一条贯穿的脊 */
.ghalo{position:absolute;top:0;bottom:0;background:var(--tint-crit);border-radius:5px}
.gtrack .gbar{z-index:1}
.gsec{display:grid;grid-template-columns:196px 1fr;align-items:center;height:30px;background:var(--plane);
  border-top:1px solid var(--grid);border-bottom:1px solid var(--grid);position:relative;z-index:1}
.gsec .glab{background:var(--plane);font-weight:650;color:var(--ink);font-size:12.5px}
.gact{font-size:11.5px;color:var(--muted);padding-left:12px}
.ghead{height:30px;border-bottom:1px solid var(--axis)}
.ghead .glab{color:var(--muted);font-size:11.5px;justify-content:flex-end}
.gwk{position:absolute;top:0;height:30px;display:flex;flex-direction:column;justify-content:center;
  align-items:center;font-variant-numeric:tabular-nums;line-height:1.25}
.gwk b{font-size:11.5px;font-weight:650;color:var(--ink-2)}
.gwk span{font-size:10.5px;color:var(--muted)}
.gbody{position:relative}
.gbg,.gnowlay{position:absolute;top:0;bottom:0;left:196px;right:0;pointer-events:none}
.gbg{z-index:0}
.gnowlay{z-index:2}
.gline{position:absolute;top:0;bottom:0;width:1px;background:var(--grid)}
.gband{position:absolute;top:0;bottom:0;background:var(--tint)}
.gband.key{background:transparent;border-left:1px dashed var(--crit);border-right:1px dashed var(--crit)}
.gnow{position:absolute;top:0;bottom:0;width:2px;background:var(--ink)}
.ghand .glab{color:var(--muted);font-size:11.5px}
.ghchip{position:absolute;top:4px;height:17px;line-height:17px;text-align:center;font-size:10.5px;
  border-radius:4px;background:var(--plane);border:1px solid var(--border);color:var(--ink-2);
  overflow:hidden;white-space:nowrap}
.ghchip.key{border-color:var(--crit);color:var(--crit);font-weight:650}
.ghchip.done{color:var(--muted)}

/* 欠账 */
.blockers{display:grid;gap:12px}
.blk{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:15px 16px}
.blk-who{display:flex;align-items:center;gap:8px;margin-bottom:8px}
.who{font-weight:650;font-size:13px;background:var(--plane);border:1px solid var(--border);
  border-radius:7px;padding:2px 9px}
.arrow{color:var(--muted);font-size:12px}
.blk-what{font-size:13.5px}
.blk-imp{font-size:12.5px;color:var(--ink-2);margin-top:8px}
.blk-imp .k{color:var(--muted);margin-right:6px}
.blk-p{font-size:11.5px;color:var(--muted);margin-top:10px;border-top:1px solid var(--grid);padding-top:8px}

/* 表格 */
.filters{display:flex;gap:8px;margin-bottom:10px;flex-wrap:wrap}
.filters .btn[aria-pressed="true"]{color:var(--ink);border-color:var(--s1);background:var(--plane)}
.tw{overflow-x:auto;border-radius:12px;border:1px solid var(--border)}
table{width:100%;border-collapse:collapse;background:var(--surface-1)}
th,td{text-align:left;padding:9px 12px;font-size:13px;border-top:1px solid var(--grid);vertical-align:top}
thead th{border-top:none;font-weight:600;font-size:12.5px;color:var(--ink-2);background:var(--plane)}
td.c-num,td.c-dim{font-variant-numeric:tabular-nums;color:var(--ink-2);white-space:nowrap}
td.c-src{font-size:11.5px;color:var(--muted);word-break:break-word}
.c-owner{white-space:nowrap;font-weight:600}
.owner-dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--c);margin-right:6px}
.c-state{white-space:nowrap;color:var(--ink-2);font-size:12.5px}
.chip{display:inline-block;font-size:12px;border:1px solid var(--border);border-radius:99px;padding:1px 10px;color:var(--ink-2);white-space:nowrap}
tr.hide{display:none}
footer{margin-top:40px;padding-top:16px;border-top:1px solid var(--grid);color:var(--muted);font-size:12.5px}
code{font-family:ui-monospace,Consolas,monospace;font-size:12.5px;background:var(--plane);
  border:1px solid var(--border);border-radius:5px;padding:1px 5px}
@media print{
  body{background:#fff}
  .btn{display:none}
  .hero,.tile,.lane,.blk,table{break-inside:avoid}
}
</style>
</head>
<body>
<div class="wrap">

<header class="hdr">
  <div>
    <h1>FPGA 创新设计竞赛 · 项目进度</h1>
    <p class="sub">后量子密码 ML-KEM 的 NTT / INTT / 点乘 FPGA 加速核 ｜ 3.3 自主选题（初级组）｜ 纯 PL 实现</p>
    <p class="meta">本页由 <code>node status/gen_status.mjs</code> 生成 · 生成时间 ${esc(nowText())} · ${esc(repoLine)}</p>
  </div>
  <button class="btn" id="theme" type="button">切换明暗</button>
</header>

<section class="hero">
  <div class="hero-num"><span class="n">${Math.round(barPct)}</span><span class="u">% 已交付</span></div>
  <div class="hero-side">
    <div class="hero-l">周计划 <b>${barDone}/${barTotal}</b> 条已交付${
      barDoing ? ` · 另有 <b>${barDoing}</b> 条进行中（含则 ${barPctWithDoing}%）` : ''}</div>
    <div class="meter" title="已交付 ${barDone} 条 · 进行中 ${barDoing} 条 · 共 ${barTotal} 条周计划（分母＝下面甘特图上的条数，不是里程碑数）">
      <div class="meter-fill" style="width:${barPct}%"></div>${
      barDoing ? `<div class="meter-do" style="left:calc(${barPct}% + 2px);width:calc(${pct(barDoing, barTotal)}% - 2px)"></div>` : ''}
    </div>
    <div class="hero-2">按日历应到 <b>${dayPct}%</b>（第 ${dayPassed}/${dayTotal} 天：${esc(planFrom)} → ${esc(cd.submission)}）${esc(paceWord)}</div>
    <div class="meter-cap">距 <strong>${esc(cd.submission)}</strong> ${esc(cd.submission_label)}还有 <b>${subDays}</b> 天 · ${esc(cd.finals_label)}（${esc(cd.finals)}）</div>
  </div>
  ${entryHead}
</section>

<h2>进度<span class="h2n">横轴＝团队计划的真实周次（team/ 三份周计划）· 一行＝一条线一周</span></h2>
${ganttNote}
${ganttHtml}

<h2>三条线现在在哪<span class="h2n">现在 / 下一步</span></h2>
<div class="nows">${nows}</div>

<h2>数字一览<span class="h2n">每块底部都写着来源</span></h2>
<div class="tiles">${tiles.join('')}</div>
<p class="hint">仓库规模（自动 · git ls-files，跳过草稿与数据目录）：${esc(scaleLine)}</p>

<h2>欠账<span class="h2n">谁欠谁一句话 / 一个文件 —— 图中挂 ⚠ 的就是这三条</span></h2>
<div class="blockers">${blockers}</div>

<h2>待办<span class="h2n">只列下一步，完整清单在 logs/ 与 team/</span></h2>
<div class="filters" id="filters">
  <button class="btn" type="button" data-f="all" aria-pressed="true">全部</button>
  <button class="btn" type="button" data-f="A" aria-pressed="false">只看 A</button>
  <button class="btn" type="button" data-f="B" aria-pressed="false">只看 B</button>
  <button class="btn" type="button" data-f="C" aria-pressed="false">只看 C</button>
</div>
<div class="tw"><table id="todos">
  <thead><tr><th>谁</th><th>做什么</th><th>状态</th><th>出处</th></tr></thead>
  <tbody>${todoRows}</tbody>
</table></div>

<h2>文档新鲜度<span class="h2n">自动化：取每份文档头部第一个日期</span></h2>
<div class="tw"><table>
  <thead><tr><th>文档</th><th>是什么</th><th>自称更新</th><th>新鲜度</th></tr></thead>
  <tbody>${docRows}</tbody>
</table></div>

<h2>数据来源<span class="h2n">哪些是自动抓的、哪些是人写的</span></h2>
<div class="tw"><table>
  <thead><tr><th>数据</th><th>来源</th><th>怎么来的</th></tr></thead>
  <tbody>${provRows}</tbody>
</table></div>

<footer>
  重跑：在仓库根目录执行 <code>node status/gen_status.mjs</code>（零依赖、不联网，只读仓库）。<br>
  人的判断（下一步 / 卡点 / 里程碑 / 主图的每一根条）写在 <code>status/status.json</code> —— 那份文件是这部分内容的唯一真源。<br>
  主图的横轴日期抄自 <code>team/</code> 下三份周计划，没有另行推算；图上每一根条悬停都能看到它的原文与出处。<br>
  文档新鲜度是启发式的：取每份文档前 25 行里第一个 <code>YYYY-MM-DD</code>（文档自己写的更新日期）；
  取不到就用 git 最后改动日期兜底，表里标 <code>(git)</code>。两者都不等于「内容确实核过」的那一天。
</footer>

</div>
<script>
(function(){
  var root=document.documentElement, btn=document.getElementById('theme');
  try{ var s=localStorage.getItem('fpga-status-theme'); if(s) root.setAttribute('data-theme',s); }catch(e){}
  function isDark(){
    var t=root.getAttribute('data-theme');
    if(t==='dark') return true;
    if(t==='light') return false;
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  }
  if(btn) btn.addEventListener('click',function(){
    var next=isDark()?'light':'dark';
    root.setAttribute('data-theme',next);
    try{ localStorage.setItem('fpga-status-theme',next); }catch(e){}
  });
  var f=document.getElementById('filters');
  if(f) f.addEventListener('click',function(e){
    var b=e.target.closest('button[data-f]'); if(!b) return;
    var want=b.getAttribute('data-f');
    [].forEach.call(f.querySelectorAll('button'),function(x){ x.setAttribute('aria-pressed', String(x===b)); });
    [].forEach.call(document.querySelectorAll('#todos tbody tr'),function(tr){
      tr.classList.toggle('hide', want!=='all' && tr.getAttribute('data-owner')!==want);
    });
  });
})();
</script>
</body>
</html>
`;
}

function isoToday() {
  const n = new Date();
  return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, '0')}-${String(n.getDate()).padStart(2, '0')}`;
}
function nowText() {
  const n = new Date();
  const p = (x) => String(x).padStart(2, '0');
  return `${n.getFullYear()}-${p(n.getMonth() + 1)}-${p(n.getDate())} ${p(n.getHours())}:${p(n.getMinutes())}`;
}
function ownerColor(json, owner) {
  const t = json.tracks.find((x) => x.id === owner);
  return t ? t.color : 1;
}

// ─────────────────────────────────────────────────────────── 入口

function main() {
  const raw = readUtf8('status/status.json');
  if (raw === null) { console.error('找不到 status/status.json'); process.exit(1); }
  let json;
  try { json = JSON.parse(raw); } catch (e) { console.error('status.json 不是合法 JSON：' + e.message); process.exit(1); }

  // 缺字段就补空，页面照常渲染（不崩）
  json.tracks ??= [];
  json.blockers ??= [];
  json.milestones ??= [];
  json.todos ??= [];
  json.manual_numbers ??= [];
  json.countdown ??= {};

  const activity = collectGitActivity(json.tracks);
  const repo = collectRepoState();
  const dirStats = collectDirStats();
  const docs = collectDocFreshness();

  const html = render({ json, activity, repo, dirStats, docs });

  // 自检：不许引用任何外部资源（离线可开）
  const external = html.match(/(?:src|href)\s*=\s*["'](https?:)?\/\//gi) || [];
  if (external.length) {
    console.error('自检失败：页面引用了外部资源 →', external.join(', '));
    process.exit(1);
  }
  if (!/<table/.test(html) || html.length < 4000) {
    console.error('自检失败：产物不完整（长度 ' + html.length + '）');
    process.exit(1);
  }

  if (CHECK_ONLY) {
    console.log('自检通过 · 产物长度 ' + html.length + ' 字节 · 未写文件');
    return;
  }
  writeFileSync(OUT, html, 'utf8');
  console.log(`已生成 ${OUT}`);
  console.log(`  提交活动：${activity.map((a) => `${a.id} 最后 ${a.last ?? '无'} / 近7天 ${a.in7}`).join(' · ')}`);
  console.log(`  文档 ${docs.filter((d) => d.stale !== null).length}/${docs.length} 份取到日期 · 目录 ${dirStats.filter((d) => d.exists).length} 个`);
}

main();
