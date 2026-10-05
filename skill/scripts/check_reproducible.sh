#!/bin/sh
# ===========================================================================
# check_reproducible.sh —— 「别人 clone 下来能不能跑通」
#
# 为什么需要这个脚本：
#   「在我机器上能跑」证明不了任何事 —— **本机可能有忘了入库的产物文件**。
#   本项目真实踩过：两条脚本依赖三个编译出来的 `.exe`，而 `*.exe` 被
#   `.gitignore` 挡住了、根本没进仓库。本机因为留着上次的 `.exe`，一直看不出问题;
#   换一台机器（或评委）一跑就是 `EXIT=1`。
#
#   所以判据必须是：**在一个干净的临时目录里做一次全新 clone，然后从零跑。**
#
# 用法：
#   sh check_reproducible.sh                       # 跑默认的四个入口脚本
#   sh check_reproducible.sh <脚本相对路径> [...]   # 只跑指定的
#   sh check_reproducible.sh --from-remote         # 从远端地址 clone（评委视角）
#   sh check_reproducible.sh --keep                # 保留临时目录，便于进去看
#
# ⚠️ 默认从**本地仓库** clone（离线、快）。它能查出「依赖未入库的产物」，
#    但**查不出「文件没 push」** —— 那要 `--from-remote`。
#    交给评审判定「可复现」之前，请用 `--from-remote` 跑一遍。
#
# 退出码：0 = 全部通过；1 = 有脚本失败；2 = 环境不满足（缺工具）
#
# 依赖：sh + git + awk。
#   **被检查的脚本本身**还有各自依赖（本项目是 gcc / iverilog / python3）——
#   缺什么脚本会列出来，并把这些脚本标成「跳过」，而不是给一个看不懂的失败。
# ===========================================================================

set -u

FROM_REMOTE=0
KEEP=0
SCRIPTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from-remote) FROM_REMOTE=1; shift ;;
        --keep)        KEEP=1;        shift ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        *) SCRIPTS="$SCRIPTS $1"; shift ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# 默认：把仓库文档里写的入口脚本都跑一遍
if [ -z "$SCRIPTS" ]; then
    SCRIPTS=" refsim/run_fntt_check.sh refsim/run_intt_pwm2_check.sh refsim/run_polmul_check.sh refsim/run_ntt_layers.sh"
fi

# ---- 把 clone 源转成 git 认的路径形态 ------------------------------------
# ⚠️ Windows（Git Bash / MSYS）上 `pwd` 给的是 `/c/Users/...` 形态。
#    路径里只要有一个撇号，MSYS 的路径转换就会失效 —— 实测：
#      git clone "/c/Users/l'x/Desktop/FPGA"  →  repository '...' does not exist
#      git clone "C:/Users/l'x/Desktop/FPGA"  →  成功
#    所以交给 git 之前先转成 `C:/...` 原生形态。有 cygpath 就用它，
#    否则手写转换（只匹配 `/d/` 这种「单字母盘符」，Linux 的 /home/... 不受影响）。
to_native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s' "$1" | sed -E 's|^/([A-Za-z])/|\1:/|'
    fi
}

# ---- 从哪 clone ----------------------------------------------------------
if [ "$FROM_REMOTE" -eq 1 ]; then
    if ! SRC=$(git -C "$REPO" remote get-url origin 2>/dev/null); then
        echo "❌ 取不到 origin 地址（--from-remote 需要先配好 remote）" >&2
        exit 2
    fi
    echo "源：远端 $SRC"
else
    SRC="$(to_native_path "$REPO")"
    echo "源：本地仓库 $SRC"
    echo "    （本地 clone 查不出「文件没 push」，判定可复现请用 --from-remote）"
fi

# ---- 工具预检 -------------------------------------------------------------
# ⚠️ 必须**真跑一下**，不能只看 `command -v`。
#    Windows 的 PATH 里常常有 WindowsApps 的占位符（`python3.exe` 只是个跳转存根），
#    `command -v python3` 说"有"，实际一跑退出码 49、没有任何输出。
#    这是本项目实测踩过的坑 —— 只看 command -v 会把缺工具误判成有工具，
#    然后给出一个「没有失败但也没真跑」的假通过。
echo
echo "工具预检（真跑一下，不只看 command -v）："
missing=""

check_tool() {   # check_tool <显示名> <命令> [版本参数]
    name="$1"; cmd="$2"; shift 2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  ❌ $name  未找到"
        missing="$missing $name"
        return 1
    fi
    out=$("$cmd" "$@" 2>&1); st=$?
    if [ "$st" -ne 0 ] || [ -z "$out" ]; then
        echo "  ❌ $name  命令存在但跑不通（退出码 $st，无输出）"
        echo "         —— 很可能是 WindowsApps 占位符，不是真的装上了"
        missing="$missing $name"
        return 1
    fi
    echo "  ✅ $name  $(printf '%s' "$out" | head -1)"
    return 0
}

check_tool gcc      gcc      --version
check_tool python3  python3  --version
check_tool iverilog iverilog -V || {
    # 不在 PATH 时，看项目约定的安装位置
    if [ -x /c/iverilog/bin/iverilog ] || [ -x /c/iverilog/bin/iverilog.exe ]; then
        echo "  ✅ iverilog（在 /c/iverilog/bin，不在 PATH —— 本项目脚本会自己加）"
        missing=$(printf '%s' "$missing" | sed 's/ iverilog//')
    else
        echo "       常见安装位置 /c/iverilog/bin 也没有"
    fi
}

if [ -n "$missing" ]; then
    echo
    echo "⚠️ 缺工具：$missing"
    echo "   Windows 上可以这样装："
    echo "     winget install --id Icarus.Verilog"
    echo "     winget install --id Python.Python.3.12"
    echo "     gcc 最麻烦：装 MSYS2（含 mingw-w64）或 WinLibs"
fi

# ---- 全新 clone ----------------------------------------------------------
TMP=$(mktemp -d)
CLONE="$TMP/repo"
echo
echo "全新 clone → $CLONE"
if ! git clone -q "$SRC" "$CLONE" 2>&1; then
    echo "❌ clone 失败"
    rm -rf "$TMP"
    exit 2
fi
echo "  ✅ clone 完成：$(git -C "$CLONE" rev-parse --short HEAD) " \
     "$(git -C "$CLONE" log -1 --format=%s)"

# ---- 断言：clone 里不该有产物文件 ----------------------------------------
echo
echo "产物文件检查（这些应该被 .gitignore 挡住、不该进仓库）："
arts=$(find "$CLONE" -type f \( -name '*.exe' -o -name '*.vvp' -o -name '*.o' -o -name '*.out' \) \
       -not -path '*/.git/*' 2>/dev/null)
if [ -z "$arts" ]; then
    echo "  ✅ 一个都没有"
else
    echo "  ⚠️ 发现以下的产物被入库了（说明靠产物跑通，不是靠源码）："
    printf '%s\n' "$arts" | sed 's|^|    |'
fi

# ---- 逐个跑 --------------------------------------------------------------
n_run=0; n_ok=0; n_skip=0; n_fail=0
for s in $SCRIPTS; do
    [ -n "$s" ] || continue
    if [ ! -f "$CLONE/$s" ]; then
        echo
        echo "[$s] ❌ 文件不存在于 clone 中"
        n_fail=$((n_fail + 1))
        continue
    fi
    if [ -n "$missing" ]; then
        echo
        echo "[$s] ⏭ 跳过（缺工具：$missing）"
        n_skip=$((n_skip + 1))
        continue
    fi
    echo
    echo "[$s] 跑……"
    if ( cd "$CLONE" && sh "$s" ) > "$TMP/out.log" 2>&1; then
        echo "  ✅ 通过（最后 3 行）"
        tail -3 "$TMP/out.log" | sed 's|^|    |'
        n_ok=$((n_ok + 1))
    else
        echo "  ❌ 失败，最后 15 行："
        tail -15 "$TMP/out.log" | sed 's|^|    |'
        n_fail=$((n_fail + 1))
    fi
    n_run=$((n_run + 1))
done

# ---- 顺手看工作区是否干净 -------------------------------------------------
dirty=$(git -C "$CLONE" status --porcelain | head -5)
echo
if [ -z "$dirty" ]; then
    echo "跑完之后工作区干净（没有留下未跟踪的脏文件）✅"
else
    echo "⚠️ 跑完之后工作区有未跟踪文件（脚本没清理干净）："
    printf '%s\n' "$dirty" | sed 's|^|    |'
fi

# ---- 汇总 ----------------------------------------------------------------
echo
echo "----------------------------------------------"
printf '通过 %d ／ 跳过 %d ／ 失败 %d\n' "$n_ok" "$n_skip" "$n_fail"

if [ "$KEEP" -eq 1 ]; then
    echo "临时目录保留在：$CLONE"
else
    rm -rf "$TMP"
fi

if [ "$n_fail" -gt 0 ]; then
    echo "❌ 有脚本在全新 clone 上失败 —— 这就是「在我机器上能跑」的真相。"
    exit 1
fi
if [ -n "$missing" ]; then
    echo "⚠️ 没有失败，但也没真跑（缺工具）。装齐工具再跑一遍才算数。"
    exit 2
fi
echo "✅ 全新 clone 上全部通过。"
exit 0
