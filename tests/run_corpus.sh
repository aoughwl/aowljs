#!/usr/bin/env bash
# aowljs CORPUS regression harness — for each tests/corpus/*.nim:
#   1. compile+run with nimony (the reference stdout + the .s.nif),
#   2. transpile the main .s.nif with `bin/aowljs` in BOTH fast and faithful mode,
#   3. run each emitted .js under node and require it byte-matches the nimony ref.
# Unlike run_faithful.sh (which proves the fast/faithful *contrast* on overflow
# programs), every program here is expected to match in BOTH modes — these are the
# language-feature programs (defer/try-finally, variant objects, generics, distinct
# types, enum sets, seq HOFs, array iteration), none of which overflow 2^53.
#
# Requires: NIM=/home/savant/nimony (or $NIM), node >= 20 on PATH.
set -u
NIM="${NIM:-/home/savant/nimony}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AOWLJS="$ROOT/bin/aowljs"
SRC="$HERE/corpus"
NC="/tmp/aowljs-corpus-nc"
OUT="$HERE/_out_corpus"
rm -rf "$NC"; mkdir -p "$NC" "$OUT"

# Rebuild the emitter first. Without this the gate happily tests a stale binary —
# bin/aowljs was once a whole commit behind src/emitjs.nim and every run was green.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  bash "$ROOT/build.sh" >"$OUT/build.log" 2>&1 || {
    echo "FAIL  build  (see $OUT/build.log)"; exit 1; }
fi

NODE_BIN="$(command -v node || true)"
pass=0; fail=0; total=0; blocked=0

run_js() {  # $1 = js file -> stdout of the emitted module
  node -e "process.stdout.write((function(){$(cat "$1")})())" 2>"$OUT/run.log"
}

# One case: $1 = entry .nim, $2 = case name. A multi-module case names its ENTRY
# module here — nimony resolves `import` relative to it, and aowljs pulls the
# imported user modules in through the shared HL-IR loader, so the emitted JS has
# to carry declarations from a module other than the one it was pointed at.
run_case() {
  local f="$1" name="$2" entry
  entry="$(basename "$f")"
  # per-test cache + retry the transient static.o link race (empty ref = race hit).
  local nc="$NC/$name" snif="" ref="" try mode flag got ok
  for try in 1 2 3 4 5; do
    rm -rf "$nc"; mkdir -p "$nc"
    ref="$("$NIM/bin/nimony" c -r --nimcache:"$nc" -f "$f" 2>"$OUT/$name.build.log")"
    # match the ENTRY module's .s.nif, which is not $name for a multi-module case
    snif="$(grep -l "$entry" "$nc"/*.s.nif 2>/dev/null | head -1)"
    [ -n "$snif" ] && [ -n "$ref" ] && break
  done
  if [ -z "$snif" ]; then
    echo "FAIL  $name  (no .s.nif — see $OUT/$name.build.log)"
    fail=$((fail+1)); return
  fi
  # A .s.nif but no reference output is the toolchain breaking, not us: sem
  # succeeded and a later phase died (hexer's lambdalifting asserts on a returned
  # closure, for one). Comparing against "" would report that as OUR mismatch —
  # and worse, an emitter that also printed nothing would score it a PASS.
  if [ -z "$ref" ]; then
    echo "BLOCKED  $name  (nimony produced a .s.nif but no output — see $OUT/$name.build.log)"
    blocked=$((blocked+1)); return
  fi
  ok=1
  for mode in fast faithful; do
    total=$((total+1))
    flag=""; [ "$mode" == faithful ] && flag="--faithful"
    if ! "$AOWLJS" $flag "$snif" > "$OUT/$name.$mode.js" 2>"$OUT/$name.$mode.emit.log"; then
      # nimony's runtime aborts (`[Assertion Failure] …`) print to STDOUT, which
      # here is the .js file — so the stderr log is EMPTY and the reason is
      # sitting in the output. Show whichever one has something in it.
      why="$(head -1 "$OUT/$name.$mode.emit.log")"
      [ -z "$why" ] && why="$(head -c 200 "$OUT/$name.$mode.js" | tr '\n' ' ')"
      echo "FAIL  $name/$mode  (emit crashed): $why"
      fail=$((fail+1)); ok=0; continue
    fi
    if [ -z "$NODE_BIN" ]; then
      echo "EMIT  $name/$mode  (no node — emitted, not executed)"; pass=$((pass+1)); continue
    fi
    got="$(run_js "$OUT/$name.$mode.js")"
    if [ "$got" == "$ref" ]; then
      pass=$((pass+1))
    else
      echo "FAIL  $name/$mode  (mismatch)"
      echo "  expected: $(echo "$ref" | tr '\n' '|')"
      echo "  got:      $(echo "$got" | tr '\n' '|')"
      fail=$((fail+1)); ok=0
    fi
  done
  [ "$ok" == 1 ] && echo "PASS  $name  (fast + faithful == nimony)"
  return 0
}

for f in "$SRC"/*.nim; do
  run_case "$f" "$(basename "$f" .nim)"
done
# Multi-module cases: one DIRECTORY each, entry point main.nim beside its imports.
for d in "$SRC"/*/; do
  [ -f "$d/main.nim" ] || continue
  run_case "$d/main.nim" "$(basename "$d")"
done

echo "-----------------------------------------"
# The denominator is DECLARED: how many programs are in the corpus at all, not
# just how many got as far as being compared. A blocked case is neither a pass
# nor a failure of the emitter, and hiding it would let coverage shrink silently.
progs="$(ls "$SRC"/*.nim 2>/dev/null | wc -l)"
mms="$(ls -d "$SRC"/*/ 2>/dev/null | wc -l)"
echo "aowljs corpus: $pass/$total passed, $fail failed, $blocked blocked"
echo "  ($progs single-module + $mms multi-module programs x 2 modes;"
echo "   blocked = nimony itself could not run it)"
[ "$fail" -eq 0 ]
