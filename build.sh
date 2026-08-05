#!/usr/bin/env bash
# Build bin/aowljs from src/aifjs_cli.nim with nimony.
#
# There was no build script here before, and it showed: bin/aowljs was a commit
# behind src/ (it still emitted the old `v_<symbol>` mangle after the readable-name
# commit landed), so every test ran against an emitter nobody had rebuilt. The gate
# calls this first now, which makes that drift impossible.
#
# nimony puts the linked executable inside <nimcache>/<module-hash>/, not beside the
# source, so the copy-out step below is part of the build, not a convenience.
set -euo pipefail
NIM="${NIM:-/home/savant/nimony}"
HL="${HL:-/home/savant/aowlhl}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
NC="${NC:-$ROOT/nimcache}"

mkdir -p "$NC" "$ROOT/bin"
# aowlhl imports nimony's own model/tag modules, which do not live in one directory.
${NIMLOCK:-} "$NIM/bin/nimony" c \
  -p:"$HL/src" \
  -p:"$NIM/src/nimony" \
  -p:"$NIM/src/models" \
  --nimcache:"$NC" \
  "$ROOT/src/aifjs_cli.nim"

exe="$(find "$NC" -type f -name aifjs_cli -newermt '-10 minutes' | head -1)"
[ -z "$exe" ] && exe="$(find "$NC" -type f -name aifjs_cli | head -1)"
if [ -z "$exe" ]; then
  echo "build.sh: nimony reported success but produced no binary under $NC" >&2
  exit 1
fi
cp "$exe" "$ROOT/bin/aowljs"
echo "built $ROOT/bin/aowljs"
