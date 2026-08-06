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
# aowlabi is the stack's ONE layout engine; src/abisize.nim maps a NIF type onto
# it so `sizeof` of an aggregate is answered rather than reported as a gap. A
# declared, checked dependency — not a vendored copy, which would put a third
# implementation of C struct layout in the stack.
ABI="${ABI:-/home/savant/aowlabi}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
NC="${NC:-$ROOT/nimcache}"

mkdir -p "$NC" "$ROOT/bin"
[ -d "$ABI/src" ] || {
  echo "build.sh: no aowlabi checkout at $ABI — src/abisize.nim needs its layout" >&2
  echo "  engine to answer sizeof of an aggregate. Clone aoughwl/aowlabi, or set ABI=." >&2
  exit 1
}
# aowlhl imports nimony's own model/tag modules, which do not live in one directory.
${NIMLOCK:-} "$NIM/bin/nimony" c \
  -p:"$HL/src" \
  -p:"$ABI/src" \
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
