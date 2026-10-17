#!/bin/sh
# New entry; the original six scripts remain unchanged.
set -eu
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PATH="/c/iverilog/bin:$PATH"
export PYTHONIOENCODING=utf-8
exec python "$HERE/check_polmul_param.py" "$@"
