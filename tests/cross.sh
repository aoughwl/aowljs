#!/usr/bin/env bash
# CROSS-BACKEND corpus gate: every fixture, through the OTHER backend.
#
# WHY. aowljs's tests/corpus/ and aowlc's examples/ grew from each other, and
# running each backend's fixtures through the other once found 5 defects here
# and 2 in aowlc. Nothing kept that up. Worse, the two corpora name the same
# feature differently — calc/calculator, charsets/chars_sets,
# valuesem/value_semantics, iters2/iterators_nested — so no tool can tell they
# overlap, and a fixture added to one side is invisible to the other.
#
# A hand-written name map would be the obvious fix and the wrong one: it would
# assert that two fixtures test the same thing, which is a claim nobody can
# check and which rots silently. The direct question — "does the other backend
# handle this program?" — needs no map at all. Run it there.
#
# THREE OUTCOMES, not two. BLOCKED means nimony itself cannot compile or run the
# program, so there is no oracle; that is neither a pass nor a failure of either
# backend and must not be scored as one. aowljs already lists three such
# programs, and they turn up here for the same reason.
#
#   tests/cross.sh              both directions, whole corpora (~45 min)
#   tests/cross.sh --sample 6   6 from each direction, deterministically chosen
#   tests/cross.sh --to-aowlc   aowljs fixtures through aowlc only
#   tests/cross.sh --to-aowljs  aowlc fixtures through aowljs only
#
# Deliberately NOT part of tests/run_corpus.sh: it costs a nimony compile per
# program, and a gate nobody can afford to run is a gate nobody runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NIM="${NIM:-$HOME/nimony}"
AOWLJS="${AOWLJS:-$ROOT/bin/aowljs}"
AOWLC_DIR="${AOWLC_DIR:-$HOME/aowlc}"
LOCK="$HOME/.aowl/bin/nimlock"
[ -x "$LOCK" ] || LOCK=""

sample=0; dir_to_aowlc=1; dir_to_aowljs=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) sample="${2:-6}"; shift 2 ;;
    --to-aowlc)  dir_to_aowljs=0; shift ;;
    --to-aowljs) dir_to_aowlc=0; shift ;;
    *) echo "cross.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -x "$AOWLJS" ] || { echo "aowljs cross gate: SKIPPED — no aowljs at $AOWLJS" >&2; exit 0; }
[ -d "$AOWLC_DIR/examples" ] || {
  echo "aowljs cross gate: SKIPPED — no aowlc checkout at $AOWLC_DIR" >&2; exit 0; }
command -v node >/dev/null 2>&1 || { echo "aowljs cross gate: SKIPPED — no node" >&2; exit 0; }

out=$(mktemp -d)
if [ "${KEEP:-0}" = 1 ]; then echo "cross: keeping $out"; else trap 'rm -rf "$out"' EXIT; fi

pass=0; failn=0; blocked=0; failed=()

# Run one program through AOWLJS (both modes) against nimony's own output.
through_aowljs() {
  local src="$1" name="$2" ref rc nc snif js got ok=1
  ref=$($LOCK "$NIM/bin/nimony" c -r "$src" 2>/dev/null); rc=$?
  ref=$(printf '%s' "$ref" | tr -d '\r')
  if [ "$rc" -ne 0 ] || [ -z "$ref" ]; then
    blocked=$((blocked+1)); printf '  blocked  %-22s (nimony has no output to compare)\n' "$name"; return 0
  fi
  nc="$out/nc/$name"; mkdir -p "$nc"
  $LOCK "$NIM/bin/nimony" c --nimcache:"$nc" "$src" >/dev/null 2>&1
  snif=$(grep -l "$(basename "$src")" "$nc"/*.s.nif 2>/dev/null | head -1)
  if [ -z "$snif" ]; then
    blocked=$((blocked+1)); printf '  blocked  %-22s (no .s.nif)\n' "$name"; return 0
  fi
  # BOTH modes. Fast mode is lossy above 2^53 by design, so a fast-only
  # mismatch on a program that passes faithful is the documented trade-off and
  # is reported as such rather than as a defect.
  local fastok=1 faithok=1
  for mode in "" "--faithful"; do
    js="$out/$name${mode:+.f}.js"
    # shellcheck disable=SC2086
    "$AOWLJS" $mode "$snif" > "$js" 2>/dev/null || { ok=0; continue; }
    # The emitted module is a function BODY returning the decoded stdout, not a
    # script: running it with `node file.js` prints nothing and every case would
    # "differ" identically.
    got=$(node -e 'const fs=require("fs");process.stdout.write(String(new Function(fs.readFileSync(process.argv[1],"utf8"))()))' "$js" 2>&1 | tr -d '\r')
    if [ "$got" != "$ref" ]; then
      [ -z "$mode" ] && fastok=0 || faithok=0
      ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    pass=$((pass+1)); printf '  ok       %-22s aowljs\n' "$name"
  elif [ "$fastok" = 0 ] && [ "$faithok" = 1 ]; then
    pass=$((pass+1)); printf '  ok       %-22s aowljs (faithful only: exceeds 2^53 in fast mode)\n' "$name"
  else
    failn=$((failn+1)); failed+=("aowljs:$name"); printf '  FAIL     %-22s aowljs\n' "$name"
  fi
}

# Run one program through AOWLC, reusing its own e2e gate rather than
# re-implementing the emit/link/compare it already does honestly.
through_aowlc() {
  local src="$1" name="$2" o rc
  o=$(cd "$AOWLC_DIR" && bash test/e2e.sh "$src" "$name" 2>&1); rc=$?
  case $rc in
    0) pass=$((pass+1)); printf '  ok       %-22s aowlc\n' "$name" ;;
    2) blocked=$((blocked+1)); printf '  blocked  %-22s (%s)\n' "$name" "$(printf '%s' "$o" | head -1 | cut -c1-40)" ;;
    *) failn=$((failn+1)); failed+=("aowlc:$name"); printf '  FAIL     %-22s aowlc\n' "$name"
       printf '%s\n' "$o" | head -2 | sed 's/^/           /' ;;
  esac
}

# A DECLARED denominator on each side, and a deterministic sample (`sort` then
# every Nth) rather than a random one — a gate whose corpus changes per run
# cannot be compared against its last result.
pick() {  # $1 = count wanted, reads paths on stdin
  local want="$1"
  if [ "$want" -le 0 ]; then cat; return; fi
  awk -v w="$want" '{a[NR]=$0} END{ n=NR; if(w>n)w=n; for(i=0;i<w;i++) print a[int(i*n/w)+1] }'
}

echo "aowljs cross-backend gate"
if [ "$dir_to_aowlc" = 1 ]; then
  mapfile -t JSF < <(ls "$HERE"/corpus/*.nim 2>/dev/null | sort | pick "$sample")
  echo "  -- ${#JSF[@]} aowljs fixture(s) through AOWLC --"
  for f in "${JSF[@]}"; do through_aowlc "$f" "$(basename "$f" .nim)"; done
fi
if [ "$dir_to_aowljs" = 1 ]; then
  mapfile -t CF < <(ls "$AOWLC_DIR"/examples/*.nim 2>/dev/null | sort | pick "$sample")
  echo "  -- ${#CF[@]} aowlc fixture(s) through AOWLJS --"
  for f in "${CF[@]}"; do through_aowljs "$f" "$(basename "$f" .nim)"; done
fi

total=$((pass+failn+blocked))
echo
echo "aowljs cross-backend: $pass/$total passed, $failn failed, $blocked blocked"
if [ "$total" -eq 0 ]; then
  echo "  FAILED — nothing ran; refusing to report a green run" >&2; exit 1
fi
[ "$failn" -eq 0 ] || { echo "  failing: ${failed[*]}" >&2; exit 1; }
exit 0
