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
rm -rf "$NC"; mkdir -p "$NC" "$OUT"

[ -x "$AOWLJS" ] || { echo "bench: no $AOWLJS — run build.sh first" >&2; exit 1; }
command -v node >/dev/null || { echo "bench: node not on PATH" >&2; exit 1; }

REPS="${REPS:-5}"
fail=0
printf '%-14s %10s %10s %8s\n' case emitted hand ratio

for f in "$SRC"/*.nim; do
  name="$(basename "$f" .nim)"
  ref_js="$SRC/$name.ref.js"
  [ -f "$ref_js" ] || { echo "  $name: no $name.ref.js to compare against" >&2; fail=1; continue; }

  nc="$NC/$name"; rm -rf "$nc"; mkdir -p "$nc"
  "$NIM/bin/nimony" c --nimcache:"$nc" -f "$f" >"$OUT/$name.build.log" 2>&1
  snif="$(grep -l "$name.nim" "$nc"/*.s.nif 2>/dev/null | head -1)"
  [ -n "$snif" ] || { echo "  $name: no .s.nif — see $OUT/$name.build.log" >&2; fail=1; continue; }
  "$AOWLJS" "$snif" > "$OUT/$name.js" 2>"$OUT/$name.emit.log" || {
    echo "  $name: emit failed — see $OUT/$name.emit.log" >&2; fail=1; continue; }

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
  ratio=$(node -e "process.stdout.write(($emitted_ms / $hand_ms).toFixed(2))")
  printf '%-14s %9sms %9sms %7sx\n' "$name" "$emitted_ms" "$hand_ms" "$ratio"
done

echo
echo "ratio = emitted / hand-written JS, best of $REPS. Lower is better; 1.00 means"
echo "the emitted code is as fast as the same program written in JavaScript."
exit "$fail"
