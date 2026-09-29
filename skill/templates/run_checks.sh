#!/bin/sh
# ===========================================================================
# run_checks.sh —— 一键验证脚本的骨架
#
# 用途：把「跑一遍验证」从「找文档 → 复制命令 → 改路径」变成一条命令。
#      **别人 clone 下来第一条要跑的就是它。**
#
# 设计要点（每一条对应一个踩过的坑）：
#
#   ① **用 `$(dirname "$0")` 定位自己，不写死绝对路径。**
#      每个人的仓库路径不同（本项目两台机器的盘符、用户名都不一样），
#      写死路径的脚本在别人机器上必然跑不了。
#
#   ② **在子目录里跑，但命令从仓库根发。**
#      验证脚本常常要 `cd` 到某个子目录才有相对路径可对。这里用
#      `( cd ... && ... )` 包住，让 `cd` 只在子 shell 里生效，不影响调用者。
#
#   ③ **每个工具先 `command -v`，缺了就明确报出来并给安装命令。**
#      不要让使用者面对一个「command not found」自己猜。
#
#   ④ **用 `set -e` 不如显式检查退出码** —— `set -e` 在管道和条件里
#      很容易失效，而且它会在**第一个**失败处退出，看不到后面还有哪些也失败了。
#      这里逐个跑、逐个报，最后统一给结论。
#
#   ⑤ **汇总行写死格式**（`PASS` / `FAIL`），方便机器 grep，也方便人扫一眼。
#
# 用法：
#   sh run_checks.sh              # 跑全部
#   sh run_checks.sh --quick      # 只跑最快的那条（开发时用）
#
# 退出码：0 = 全部通过；1 = 有失败；2 = 缺工具
# ===========================================================================

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"       # 本脚本所在目录（见 ①）
REPO="$(cd "$HERE/.." && pwd)"              # 仓库根，按实际层级改

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# ---- 工具预检（见 ③）------------------------------------------------------
# ⚠️ 必须**真跑一下**，不能只看 `command -v` ——
#    Windows 的 PATH 里可能有 WindowsApps 占位符（命令存在但跑不通、退出码非零）。
missing=""
need() {   # need <命令> <版本参数> <安装提示>
    cmd="$1"; ver="$2"; hint="$3"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  ❌ 缺 $cmd —— $hint"
        missing="$missing $cmd"
        return 1
    fi
    out=$("$cmd" "$ver" 2>&1); st=$?
    if [ "$st" -ne 0 ] || [ -z "$out" ]; then
        echo "  ❌ $cmd 命令存在但跑不通（退出码 $st，无输出）—— 可能是占位符，不是真装上了"
        missing="$missing $cmd"
        return 1
    fi
    echo "  ✅ $(printf '%s' "$out" | head -1)"
}

echo "工具预检："
# TODO: 改成你的工具链
#   注意 need 的第二个参数是版本参数，第三个是安装提示
need gcc      --version  "装 MSYS2 或 WinLibs"
need iverilog -V         "winget install --id Icarus.Verilog（不在 PATH 时脚本要自己 export）"
need python3  --version  "winget install --id Python.Python.3.12"

if [ -n "$missing" ]; then
    echo
    echo "缺工具：$missing"
    exit 2
fi

# ---- 逐项跑（见 ② ④）-----------------------------------------------------
n_pass=0
n_fail=0

run_one() {   # run_one <名字> <相对仓库根的目录> <命令>
    name="$1"; where="$2"; cmd="$3"
    echo
    echo "=== $name ==="
    if ( cd "$REPO/$where" && eval "$cmd" ); then
        echo "PASS  $name"
        n_pass=$((n_pass + 1))
    else
        echo "FAIL  $name"
        n_fail=$((n_fail + 1))
    fi
}

# TODO: 换成你的检查项。建议按「快 → 慢」排，开发时 --quick 只跑第一条。
run_one "数据格式"   "skill/scripts" "sh check_data_format.sh ../../data"
run_one "非退化统计" "skill/scripts" "sh check_nondegenerate.sh ../../data"
if [ "$QUICK" -eq 0 ]; then
    run_one "功能对拍"   "refsim"  "sh run_fntt_check.sh"
    run_one "可复现性"   "skill/scripts" "sh check_reproducible.sh"
fi

# ---- 汇总（见 ⑤）----------------------------------------------------------
echo
echo "----------------------------------------------"
printf '通过 %d ／ 失败 %d\n' "$n_pass" "$n_fail"
if [ "$n_fail" -eq 0 ]; then
    echo "SUMMARY ALL_PASS"
    exit 0
fi
echo "SUMMARY HAS_FAILURE"
exit 1

# ===========================================================================
# 再补一条习惯，比脚本本身重要：
#
#   **「通过」必须与「非退化」同时出现才算数。**
#   验证脚本里跑出「4096/4096 全中」的时候，顺手把「输入有多少个不同值」
#   也打出来。否则向量本身没区分度时，「全中」可能只是巧合。
#   现成脚本：`../scripts/check_nondegenerate.sh`
# ===========================================================================
