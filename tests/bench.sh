#!/usr/bin/env bash
# aowljs BENCHMARK — the README says "near-native speed". Nothing checked it.
#
# For each tests/bench/*.nim: transpile with bin/aowljs, run the emitted JS under
# node, and time it against a HAND-WRITTEN JavaScript version of the same program
# in tests/bench/<name>.ref.js. The ratio is the claim: 1.0 means the emitted
# code is as fast as JS written by hand, which is the target, because the emitted
# code IS JavaScript — there is no interpreter in the loop.
#
# This is a MEASUREMENT, not a gate: machines and JIT warm-up vary, so it prints
# and never fails on a ratio. It fails only when something does not run, or when
# the two disagree about the ANSWER — a benchmark that computes the wrong thing
# measures nothing.
set -uo pipefail
NIM="${NIM:-/home/savant/nimony}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AOWLJS="$ROOT/bin/aowljs"
SRC="$HERE/bench"
NC="/tmp/aowljs-bench-nc"
OUT="$HERE/_out_bench"
# The machine-wide compile lock. It matters more here than anywhere: this script
# reports TIMINGS, and an unlocked nimony compile racing another one does not
# just risk a corrupt link, it makes every number a measurement of the machine's
# load rather than of the emitter.
LOCK="$HOME/.aowl/bin/nimlock"
[ -x "$LOCK" ] || LOCK=""
rm -rf "$NC"; mkdir -p "$NC" "$OUT"

[ -x "$AOWLJS" ] || { echo "bench: no $AOWLJS — run build.sh first" >&2; exit 1; }
command -v node >/dev/null || { echo "bench: node not on PATH" >&2; exit 1; }

REPS="${REPS:-5}"
fail=0
# `emit` is the transpile itself, which is its own regression surface: the rename
# table was a linear scan consulted once per symbol occurrence, so emit time grew
# as O(n^2.8) and a 1.4 MB .s.nif took 11 s. It is a hash lookup now (0.19 s), and
# printing the number here is what would catch that coming back.
printf '%-14s %8s %10s %10s %8s\n' case emit emitted hand ratio

for f in "$SRC"/*.nim; do
  name="$(basename "$f" .nim)"
  ref_js="$SRC/$name.ref.js"
  [ -f "$ref_js" ] || { echo "  $name: no $name.ref.js to compare against" >&2; fail=1; continue; }

  nc="$NC/$name"; rm -rf "$nc"; mkdir -p "$nc"
  # shellcheck disable=SC2086
  $LOCK "$NIM/bin/nimony" c --nimcache:"$nc" -f "$f" >"$OUT/$name.build.log" 2>&1
  snif="$(grep -l "$name.nim" "$nc"/*.s.nif 2>/dev/null | head -1)"
  [ -n "$snif" ] || { echo "  $name: no .s.nif — see $OUT/$name.build.log" >&2; fail=1; continue; }
  emit_s=$( { /usr/bin/time -f "%e" "$AOWLJS" "$snif" > "$OUT/$name.js"; } 2>&1 ) || {
    echo "  $name: emit failed — see $OUT/$name.js" >&2; fail=1; continue; }

  # Best-of-REPS wall time, in milliseconds, plus the answer each side computed.
  read -r emitted_ms emitted_out < <(node -e '
    const fs = require("fs"), src = fs.readFileSync(process.argv[1], "utf8");
    const f = new Function(src); let best = Infinity, out;
    for (let i = 0; i < Number(process.argv[2]); i++) {
      const t = process.hrtime.bigint(); out = f(); const d = Number(process.hrtime.bigint() - t) / 1e6;
      if (d < best) best = d;
    }
    process.stdout.write(best.toFixed(2) + " " + String(out).trim().replace(/\s+/g, ","));
  ' "$OUT/$name.js" "$REPS")

  read -r hand_ms hand_out < <(node -e '
    const fs = require("fs"), src = fs.readFileSync(process.argv[1], "utf8");
    const f = new Function(src); let best = Infinity, out;
    for (let i = 0; i < Number(process.argv[2]); i++) {
      const t = process.hrtime.bigint(); out = f(); const d = Number(process.hrtime.bigint() - t) / 1e6;
      if (d < best) best = d;
    }
    process.stdout.write(best.toFixed(2) + " " + String(out).trim().replace(/\s+/g, ","));
  ' "$ref_js" "$REPS")

  if [ "$emitted_out" != "$hand_out" ]; then
    printf '  %-12s DISAGREE emitted=[%s] hand=[%s]\n' "$name" "$emitted_out" "$hand_out" >&2
    fail=1; continue
  fi
  # A sub-millisecond run time cannot support a ratio — bigmodule exists for its
  # EMIT column and runs in 0.08ms, where a "4.00x" would be pure noise inviting
  # a wrong conclusion.
  ratio=$(node -e "
    const a = $emitted_ms, b = $hand_ms;
    process.stdout.write(a < 1 || b < 1 ? '-' : (a / b).toFixed(2) + 'x');")
  printf '%-14s %7ss %9sms %9sms %8s\n' "$name" "$emit_s" "$emitted_ms" "$hand_ms" "$ratio"
done

echo
echo "ratio = emitted / hand-written JS, best of $REPS. Lower is better; 1.00 means"
echo "the emitted code is as fast as the same program written in JavaScript."
exit "$fail"
